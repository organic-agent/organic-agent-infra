# AI 분석 Lambda 셋: embedder(미리보기·DINOv3 임베딩) → score(사진별 점수) → categorize(갤러리 단위 그룹·이름).
#
# 서버의 `analysis` 도메인(분석 오케스트레이터)이 단계마다 EVENT로 부르는 함수들이다. 코드는 AI 저장소
# (organic-agent-ai)의 최상위 디렉토리 하나 = 함수 하나(`embedder/` · `score/` · `categorize/`)이고,
# 각 디렉토리의 deploy.sh가 같은 이름의 ECR(`wes-<모듈>`)에 밀고 같은 이름의 함수를 갱신한다.
#
#   wes ──EVENT {galleryId}──▶ [embedder]  S3 GET(원본) → 미리보기 PUT → DINOv3 → photo_analysis.embedding
#   wes ──EVENT {galleryId, jobId}──▶ [score]  S3 GET(미리보기) → CLIP·ARNIQA·LAION → photo_analysis 점수
#                                         └──EVENT(체인)──▶ [categorize]  그룹 묶기 → Bedrock(이름) → DONE
#
# 셋은 실행 모양이 같다 — 컨테이너 이미지, RDS와 같은 DB 서브넷, 같은 보안 그룹, 같은 DB_*/S3_BUCKET
# 환경변수, apply 밖에서 주입하는 DB_PASSWORD. 그래서 공통 골격(ECR·롤·로그·함수·비동기 설정·알람·
# SSM 파라미터)은 `local.functions` 맵 위에 for_each로 한 번만 적고, 함수마다 다른 것(메모리·임시
# 저장소·동시 실행·환경변수·IAM 권한·앱이 읽는 파라미터 이름)만 아래 맵과 정책 문서에서 갈린다.
#
# **왜 S3 ObjectCreated 트리거가 아닌가**: 브라우저가 수천 장을 올리면 Lambda 수천 개가 동시에 뜨고,
# 각자 PostgreSQL 커넥션을 연다. db.t4g.micro는 백 개 남짓에서 바닥난다. 게다가 완료 통보
# (POST /complete)와 경합해서, 방금 채운 EMBEDDED를 UPLOADED로 되돌린다. 그래서 갤러리 단위로 한 번 부른다.
#
# **왜 Fargate가 아닌가**: Fargate 태스크는 자기가 뜬 서브넷을 통해 ECR에서 이미지를 당겨온다. NAT 없는
# 이 DB 서브넷에서는 ecr.api·ecr.dkr·logs 인터페이스 엔드포인트가 더 필요해진다. Lambda의 이미지는
# Lambda 서비스가 VPC 바깥에서 당겨오므로 이미지 경로에는 네트워크 자원이 들지 않는다. 대가는 15분
# 상한이고, embedder·score는 그 앞에서 스스로 멈추고 자기 자신을 다시 부른다.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # 함수 이름은 `<prefix>-<key>`. AI 저장소 deploy.sh의 REPO_NAME/FUNCTION_NAME과 같아야 한다.
  function_names = {
    embedder   = "${var.name_prefix}-embedder"
    score      = "${var.name_prefix}-score"
    categorize = "${var.name_prefix}-categorize"
  }

  # 실행 롤 정책이 함수 ARN을 가리켜야 하는데(자기 재호출·체인), aws_lambda_function.this[*].arn을
  # 쓰면 함수 → 롤 → 정책 → 함수의 순환이 된다. 이름이 정해져 있으므로 문자열로 조립한다.
  function_arns = {
    for key, name in local.function_names :
    key => "arn:aws:lambda:${local.region}:${local.account_id}:function:${name}"
  }

  # 셋이 공유하는 DB·S3 환경변수. 이름은 AI 저장소 각 모듈 config.py(Settings.from_env)와 같다.
  # DB_PASSWORD는 일부러 없다 — state에 평문으로 남기 때문이다. 아래 lifecycle 참고.
  db_env = {
    DB_HOST   = var.db_host
    DB_PORT   = tostring(var.db_port)
    DB_NAME   = var.db_name
    S3_BUCKET = var.photo_bucket_name
  }

  # score·categorize는 코드 기본값(require)이 아니라 verify-full로 올린다. Dockerfile이 RDS CA 번들을
  # /opt/rds-ca에 굽는 이유가 이것이고, require는 인증서를 검증하지 않아 중간자가 설 자리가 남는다.
  # embedder는 코드 기본값이 이미 verify-full + 같은 경로라 넣지 않는다.
  ssl_env = {
    DB_SSLMODE     = "verify-full"
    DB_SSLROOTCERT = "/opt/rds-ca/global-bundle.pem"
  }

  functions = {
    embedder = {
      memory_mb            = var.embedder_memory_mb
      ephemeral_storage_mb = 512
      reserved_concurrency = var.embedder_reserved_concurrent_executions
      db_username          = var.embedder_db_username
      # 앱이 부팅할 때 읽는 파라미터(app.embedding.function-name). 서버의 EmbeddingProperties가 그대로라
      # 분석 파라미터와 프리픽스가 다르다 — Parameter Store 키를 옮기지 않기 위해서다.
      parameter_name = "app.embedding.function-name"
      policy_name    = "read-photos-and-connect-db"
      environment = merge(local.db_env, {
        DB_USER = var.embedder_db_username

        # photo_analysis.embedding의 vector(n), 그리고 앱의 PhotoAnalysis.EMBEDDING_DIMENSION과 같아야 한다.
        # 모델이 다른 폭을 내놓으면 잡이 첫 배치에서 스스로 멈춘다.
        EMBED_DIM        = tostring(var.embedding_dimension)
        EMBED_BATCH_SIZE = tostring(var.embedder_batch_size)
      })
    }
    score = {
      memory_mb            = var.score_memory_mb
      ephemeral_storage_mb = var.score_ephemeral_storage_mb
      reserved_concurrency = var.score_reserved_concurrent_executions
      db_username          = var.analysis_db_username
      parameter_name       = "app.analysis.score-function-name"
      policy_name          = "read-previews-and-invoke-chain"
      environment = merge(local.db_env, local.ssl_env, {
        DB_USER = var.analysis_db_username
        # 끝에서 categorize를 EVENT로 부른다(score/chain.py). 없으면 잡을 시작하기 전에 FAILED.
        CATEGORIZE_FUNCTION_NAME = local.function_names.categorize
      })
    }
    categorize = {
      memory_mb            = var.categorize_memory_mb
      ephemeral_storage_mb = var.categorize_ephemeral_storage_mb
      reserved_concurrency = var.categorize_reserved_concurrent_executions
      db_username          = var.analysis_db_username
      parameter_name       = "app.analysis.categorize-function-name"
      policy_name          = "read-previews-and-invoke-bedrock"
      environment = merge(local.db_env, local.ssl_env, {
        DB_USER = var.analysis_db_username
        # 그룹 이름 짓기. 리전은 이 스택의 리전이고, 모델은 `global.` 크로스 리전 프로필이다 —
        # 서울 온디맨드에 Sonnet이 없다(categorize/llm.py). 아래 Bedrock IAM 문장과 같은 값이어야 한다.
        BEDROCK_REGION   = local.region
        BEDROCK_MODEL_ID = var.bedrock_model_id
      })
    }
  }

  # `global.anthropic.claude-sonnet-4-6` → 기반 모델 `anthropic.claude-sonnet-4-6`. 크로스 리전 프로필로
  # 부르면 IAM은 프로필 ARN과 프로필이 라우팅하는 기반 모델 ARN 둘 다를 요구한다. 기반 모델 ARN의
  # 리전 자리는 `global.` 프로필이 빈 값(`arn:aws:bedrock:::foundation-model/…`)이라 `*`로 받는다.
  bedrock_foundation_model_id = replace(var.bedrock_model_id, "/^(global|us|eu|apac|jp|au|ca)\\./", "")
}

# --- ECR ---

resource "aws_ecr_repository" "this" {
  for_each = local.functions

  name = local.function_names[each.key]

  # 이미지가 남아 있는 리포지토리는 삭제를 거부한다. 이 스택은 한 번에 destroy 되는 것이
  # 전제라(runbook의 "폐기") 리포지토리만 남아 다음 apply를 막지 않게 한다.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# embedder·score 이미지는 torch와 가중치로 3~5GB다. 이게 없으면 다시 빌드할 때마다 이전 레이어가
# ECR 스토리지 요금을 내며 그대로 쌓인다. categorize는 작지만 규칙은 같이 둔다.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = local.functions

  repository = aws_ecr_repository.this[each.key].name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 3 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 3
      }
      action = { type = "expire" }
    }]
  })
}

# --- 실행 롤 ---

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.functions

  name_prefix        = "${local.function_names[each.key]}-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# VPC에 붙는 함수라면 반드시 필요하다. 함수를 서브넷 안에 넣는 ENI를 만들고 지우는 권한이다.
# 없으면 함수는 생성되지만 모든 호출이 핸들러에 닿기도 전에 실패한다. CloudWatch Logs 권한도 함께.
resource "aws_iam_role_policy_attachment" "vpc_access" {
  for_each = local.functions

  role       = aws_iam_role.this[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# embedder: 원본 읽기 + 미리보기 쓰기 + (막혀 있는) RDS IAM 인증 + 자기 재호출.
data "aws_iam_policy_document" "embedder" {
  # 원본을 가져와 메모리에서 임베딩한다. 벡터는 PostgreSQL로 간다.
  statement {
    sid       = "ReadPhotos"
    actions   = ["s3:GetObject"]
    resources = ["${var.photo_bucket_arn}/*"]
  }

  # 브라우저가 그릴 수 있는 파생 JPEG를 되올린다. 아이폰 원본(HEIC)은 Chrome·Firefox·Edge가
  # 디코딩하지 못해, 원본을 그대로 서명해 주면 미리보기가 비어 보인다.
  #
  # 쓰기 범위를 previews/ 접두사로 좁힌다. 이 함수가 원본을 덮어쓸 이유는 없고, 넓게 열어 두면
  # 임베딩 잡의 버그 하나가 사진작가의 원본을 지울 수 있다. score·categorize는 이 접두사만 읽는다.
  statement {
    sid       = "WritePreviews"
    actions   = ["s3:PutObject"]
    resources = ["${var.photo_bucket_arn}/previews/*"]
  }

  # 15분 타임아웃 앞에서 배치 경계에 멈추면 남은 사진을 위해 자기 자신을 EVENT로 다시 부른다
  # (embedder/handler.py의 reinvoke). 이 권한이 없거나 DB 서브넷에 Lambda 인터페이스 엔드포인트가
  # 없으면 reinvoked=false로 끝나고, 앱이 다시 불러야 이어진다 — 실패는 아니지만 큰 갤러리가
  # 매번 앱의 재호출에 기댄다.
  statement {
    sid       = "ReinvokeSelf"
    actions   = ["lambda:InvokeFunction"]
    resources = [local.function_arns.embedder]
  }

  # 원래 설계는 이 권한으로 15분짜리 접속 토큰을 만들어 비밀번호를 아예 없애는 것이었다.
  # ARN이 인스턴스 이름이 아니라 RDS 리소스 ID(db-XXXX)를 쓰는 점에 주의 — 인스턴스를
  # 다시 만들면 값이 바뀌므로 하드코딩하면 안 된다.
  #
  # **지금은 동작하지 않는다.** 조직 SCP가 계정 전체에서 rds-db:connect를 거부한다.
  # 이 계정은 멤버 계정이라 여기서는 풀 수 없고, DB 쪽(embedder 사용자, GRANT rds_iam)은
  # 이미 갖춰져 있다. 그래서 접속은 임시로 비밀번호를 쓴다 — 아래 environment 블록 참고.
  #
  # 문장을 지우지 않고 남겨 둔다. 관리 계정에서 SCP를 풀면 이 문장과 db.py의 토큰 생성만
  # 되살리면 되고, 그게 되돌아가야 할 지점이다(score·categorize에도 같은 문장을 그때 추가한다).
  # 막혀 있는 동안 이 권한은 아무것도 주지 않는다.
  statement {
    sid       = "ConnectAsEmbedder"
    actions   = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:${local.region}:${local.account_id}:dbuser:${var.db_resource_id}/${var.embedder_db_username}"]
  }
}

# score: 미리보기 읽기 + 자기 재호출 + categorize 체인.
data "aws_iam_policy_document" "score" {
  # 임베더가 만든 미리보기 JPEG만 읽는다(previews/ 접두사). 원본은 이 함수가 볼 이유가 없다.
  statement {
    sid       = "ReadPreviews"
    actions   = ["s3:GetObject"]
    resources = ["${var.photo_bucket_arn}/previews/*"]
  }

  # 15분 앞에서 배치 경계에 멈추면 남은 사진을 위해 자기 자신을 EVENT로 다시 부르고(handler.reinvoke),
  # 다 끝나면 categorize를 EVENT로 깨운다(chain.invoke_categorize). 체인이 실패하면 잡을 FAILED로 닫는다 —
  # 그래서 이 권한과 DB 서브넷의 Lambda 인터페이스 엔드포인트가 없으면 분석 잡은 하나도 끝나지 않는다.
  statement {
    sid       = "ReinvokeSelfAndChainCategorize"
    actions   = ["lambda:InvokeFunction"]
    resources = [local.function_arns.score, local.function_arns.categorize]
  }
}

# categorize: 대표 사진 몇 장 읽기 + Bedrock.
data "aws_iam_policy_document" "categorize" {
  # 그룹 이름을 지을 때 그룹 대표 미리보기 몇 장을 내려받아 VLM에 보낸다.
  statement {
    sid       = "ReadPreviews"
    actions   = ["s3:GetObject"]
    resources = ["${var.photo_bucket_arn}/previews/*"]
  }

  # 크로스 리전 프로필 호출은 프로필 ARN(이 계정·리전)과 그 프로필이 보내는 기반 모델 ARN(리전 무관)
  # 양쪽에 InvokeModel이 있어야 한다. 하나만 있으면 AccessDeniedException인데, 메시지가 프로필이
  # 없다는 것처럼 읽힌다. 스트리밍은 쓰지 않으므로 InvokeModelWithResponseStream은 주지 않는다.
  statement {
    sid     = "InvokeNamingModel"
    actions = ["bedrock:InvokeModel"]
    resources = [
      "arn:aws:bedrock:${local.region}:${local.account_id}:inference-profile/${var.bedrock_model_id}",
      "arn:aws:bedrock:*::foundation-model/${local.bedrock_foundation_model_id}",
    ]
  }
}

locals {
  policies = {
    embedder   = data.aws_iam_policy_document.embedder.json
    score      = data.aws_iam_policy_document.score.json
    categorize = data.aws_iam_policy_document.categorize.json
  }
}

resource "aws_iam_role_policy" "this" {
  for_each = local.functions

  name   = each.value.policy_name
  role   = aws_iam_role.this[each.key].id
  policy = local.policies[each.key]
}

# --- 함수 ---

# 직접 만든다. Lambda가 알아서 만든 로그 그룹은 보존 기간이 "영구"라 계속 쌓인다.
resource "aws_cloudwatch_log_group" "this" {
  for_each = local.functions

  name              = "/aws/lambda/${local.function_names[each.key]}"
  retention_in_days = 14
}

resource "aws_lambda_function" "this" {
  for_each = local.functions

  function_name = local.function_names[each.key]
  role          = aws_iam_role.this[each.key].arn

  # zip이 아니라 컨테이너 이미지다. embedder·score는 torch 하나로 압축 해제 250MB 한도를 넘고,
  # categorize는 zip으로도 가지만 셋이 같은 배포 경로(deploy.sh → ECR → update-function-code)를 쓴다.
  #
  # 리포지토리에 이 태그가 이미 있어야 한다 — 이미지 없는 ECR을 상대로는 함수가 만들어지지
  # 않는다. 첫 apply 순서는 docs/deploy-order.md에 있다.
  package_type = "Image"
  image_uri    = "${aws_ecr_repository.this[each.key].repository_url}:${var.image_tag}"

  # x86_64(기본값). 앱 컨테이너는 Graviton EC2에 올라가 arm64지만 이 함수들은 별개이고,
  # AI 저장소 deploy.sh가 --platform linux/amd64로 빌드한다.

  # 최댓값. 콜드 스타트가 수 GB짜리 이미지를 먼저 내려받고, embedder·score는 사진마다 CPU 추론을 해
  # 갤러리 하나가 15분을 넘기면 스스로 멈추고 재호출한다. categorize는 수 초 + Bedrock 몇 번이라
  # 보통 1분 안이지만, 상한을 낮춰 얻는 것이 없다.
  timeout = 900

  # Lambda에서 메모리는 CPU 다이얼이기도 하고, embedder·score는 순수 CPU 추론이다. 과금이 밀리초
  # 단위라 크고 짧은 실행과 작고 느린 실행의 비용이 대체로 같으므로, 낮게 잡아서 얻는 것이 없다.
  # score는 CLIP-L(1.7GB) + ARNIQA + torch를 올려 두어 더 크고, categorize는 torch 없이 거리행렬만 든다.
  memory_size = each.value.memory_mb

  # score는 갤러리의 미리보기 전부를 /tmp에 내려받은 뒤 점수를 매긴다(score/gallery.py load_db).
  # 장당 200KB 안팎이라 기본 512MB로는 2,500장 남짓에서 디스크가 찬다. 나머지 둘은 기본값이면 된다.
  ephemeral_storage {
    size = each.value.ephemeral_storage_mb
  }

  # 갤러리 하나가 함수 하나를 15분씩 붙들고, 자기 재호출로 이어진다. 소형 RDS와 Lambda 비용이
  # 한꺼번에 치솟지 않게 상한을 둔다. 넘치는 EVENT는 큐에서 기다리고, event age를 넘기면 버려진다 —
  # 그때는 wes의 dispatch 재시도(app.analysis.dispatch-retry-after)가 다시 보낸다.
  reserved_concurrent_executions = each.value.reserved_concurrency

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.security_group_id]
  }

  environment {
    variables = each.value.environment
  }

  depends_on = [
    aws_iam_role_policy_attachment.vpc_access,
    aws_cloudwatch_log_group.this,
  ]

  lifecycle {
    ignore_changes = [
      # 새 이미지는 같은 태그로 밀고 update-function-code로 반영한다(AI 저장소 deploy.sh). 그러면
      # Terraform이 기록해 둔 다이제스트가 곧바로 낡는다. 이게 없으면 이후 모든 plan이 함수를
      # 마지막 apply 시점의 이미지로 되돌리려 든다.
      image_uri,

      # 위 environment에 DB_PASSWORD가 없으므로, 이게 없으면 apply 때마다 손으로 넣은 키를 지운다.
      # 키 하나만 무시하므로 DB_HOST 같은 나머지 값은 정상적으로 반영된다.
      #
      # 원래는 이것조차 필요 없었다 — RDS IAM 인증으로 비밀번호 자체가 없는 설계였다. 조직 SCP가
      # rds-db:connect를 막아 임시로 되돌린 상태다(위 embedder 정책 주석, docs/runbook.md "SCP 차단").
      # 이래도 refresh는 AWS에서 값을 읽어 state에 기록한다. 즉 비밀번호는 state 파일에 남는다 —
      # Terraform이 넣지 않을 뿐이다. state 버킷은 버저닝이 켜져 있어 한 번 들어간 값은 과거 버전에도
      # 남으니, SCP가 풀려 이 우회로를 걷을 때 비밀번호도 함께 교체한다. 주입 절차는 runbook "비밀번호 주입".
      environment[0].variables["DB_PASSWORD"],
    ]
  }
}

# Lambda 서비스의 자체 재시도는 끈다. 재시도는 DB 상태를 보고 wes 분석 오케스트레이터가 맡고
# (dispatch 재시도·하트비트·max-attempts), 함수는 수락한 이벤트를 한 번만 실행한다. 20분 event age는
# 15분 함수 상한에 큐 지연 5분을 더한 값이라, 장시간 적체된 낡은 작업을 뒤늦게 실행하지 않는다.
resource "aws_lambda_function_event_invoke_config" "this" {
  for_each = local.functions

  function_name = aws_lambda_function.this[each.key].function_name

  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = var.async_event_max_age_seconds
}

# backlog가 event age 상한에 가까워지거나 실제로 버려진 경우를 CloudWatch 상태로 남겨 무음 손실을 피한다.
resource "aws_cloudwatch_metric_alarm" "async_event_age" {
  for_each = local.functions

  alarm_name          = "${local.function_names[each.key]}-async-event-age"
  alarm_description   = "${local.function_names[each.key]} async backlog age exceeded 10 minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "AsyncEventAge"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Maximum"
  threshold           = 600000
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.this[each.key].function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "async_events_dropped" {
  for_each = local.functions

  alarm_name          = "${local.function_names[each.key]}-async-events-dropped"
  alarm_description   = "${local.function_names[each.key]} dropped at least one asynchronous event"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "AsyncEventsDropped"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.this[each.key].function_name
  }
}

# --- 앱 쪽 연결 ---

# wes의 분석 오케스트레이터(LambdaStageInvoker)가 단계마다 함수를 EVENT로 부른다. 인스턴스 프로파일이
# 앱의 유일한 신원이므로 이 정책이 없으면 dispatch가 AccessDenied로 끝난다.
data "aws_iam_policy_document" "app_invoke" {
  statement {
    sid       = "InvokeAnalysisFunctions"
    actions   = ["lambda:InvokeFunction"]
    resources = [for key in keys(local.functions) : aws_lambda_function.this[key].arn]
  }
}

resource "aws_iam_role_policy" "app_invoke" {
  name   = "invoke-analysis-functions"
  role   = var.app_role_name
  policy = data.aws_iam_policy_document.app_invoke.json
}

# 앱이 부팅할 때 다른 설정과 함께 읽는다. 값이 없으면 앱은 기동은 하되 임베딩·분석 요청에 503으로
# 답한다 — 로컬에는 함수가 없는 것이 정상이라 기동을 막지 않도록 그렇게 만들어져 있다.
resource "aws_ssm_parameter" "function_name" {
  for_each = local.functions

  name  = "${var.parameter_prefix}/${each.value.parameter_name}"
  type  = "String"
  value = aws_lambda_function.this[each.key].function_name
}
