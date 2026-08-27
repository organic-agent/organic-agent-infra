# 임베딩 잡: ECR 이미지 + 갤러리 단위로 깨어나는 Lambda.
#
# 앱은 임베딩을 계산하지 않는다. 프론트가 갤러리 업로드를 마치고
# POST /api/v1/galleries/{id}/embeddings/run 을 부르면, 앱이 갤러리 id 하나를 실어
# 이 함수를 비동기로 호출하고, 함수가 그 갤러리의 사진을 훑는다 —
# S3 GET → DINOv2 → UPDATE photos SET embedding.
#
# **왜 S3 ObjectCreated 트리거가 아닌가**: 브라우저가 수천 장을 올리면 Lambda 수천 개가
# 동시에 뜨고, 각자 PostgreSQL 커넥션을 연다. db.t4g.micro는 백 개 남짓에서 바닥난다.
# 게다가 완료 통보(POST /complete)와 경합해서, 방금 채운 EMBEDDED를 UPLOADED로 되돌린다.
#
# **왜 Fargate가 아닌가**: Fargate 태스크는 자기가 뜬 서브넷을 통해 ECR에서 이미지를
# 당겨온다. NAT 없는 이 DB 서브넷에서는 ecr.api·ecr.dkr·logs 인터페이스 엔드포인트가
# 필요해진다(시간당 과금). Lambda의 이미지는 Lambda 서비스가 VPC 바깥에서 당겨오므로,
# 관여하는 네트워크 자원이 공짜인 S3 게이트웨이 엔드포인트 하나뿐이다.
# 대가는 15분 상한이고, 갤러리 하나가 그걸 넘기 시작하면 같은 이미지를 Fargate에 그대로 올린다.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_ecr_repository" "this" {
  name = "${var.name_prefix}-embedder"

  # 이미지가 남아 있는 리포지토리는 삭제를 거부한다. 이 스택은 한 번에 destroy 되는 것이
  # 전제라(runbook의 "폐기") 리포지토리만 남아 다음 apply를 막지 않게 한다.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# torch와 모델 가중치까지 들어가 이미지 하나가 3~5GB다. 이게 없으면 다시 빌드할 때마다
# 이전 레이어가 ECR 스토리지 요금을 내며 그대로 쌓인다.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

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
  name_prefix        = "${var.name_prefix}-embedder-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# VPC에 붙는 함수라면 반드시 필요하다. 함수를 서브넷 안에 넣는 ENI를 만들고 지우는 권한이다.
# 없으면 함수는 생성되지만 모든 호출이 핸들러에 닿기도 전에 실패한다.
# CloudWatch Logs 권한도 이 관리형 정책이 함께 갖고 있다.
resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "this" {
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
  # 임베딩 잡의 버그 하나가 사진작가의 원본을 지울 수 있다.
  statement {
    sid       = "WritePreviews"
    actions   = ["s3:PutObject"]
    resources = ["${var.photo_bucket_arn}/previews/*"]
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
  # 되살리면 되고, 그게 되돌아가야 할 지점이다. 막혀 있는 동안 이 권한은 아무것도 주지 않는다.
  statement {
    sid       = "ConnectAsEmbedder"
    actions   = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:dbuser:${var.db_resource_id}/${var.db_username}"]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "read-photos-and-connect-db"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.this.json
}

# 직접 만든다. Lambda가 알아서 만든 로그 그룹은 보존 기간이 "영구"라 계속 쌓인다.
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name_prefix}-embedder"
  retention_in_days = 14
}

resource "aws_lambda_function" "this" {
  function_name = "${var.name_prefix}-embedder"
  role          = aws_iam_role.this.arn

  # zip이 아니라 컨테이너 이미지다. torch 하나로 압축 해제 250MB 한도를 넘는다.
  #
  # 리포지토리에 이 태그가 이미 있어야 한다 — 이미지 없는 ECR을 상대로는 함수가 만들어지지
  # 않는다. 첫 apply 순서는 docs/deploy-order.md에 있다.
  package_type = "Image"
  image_uri    = "${aws_ecr_repository.this.repository_url}:${var.image_tag}"

  # x86_64(기본값). 앱 컨테이너는 Graviton EC2에 올라가 arm64지만 이 함수는 별개이고,
  # embedder/README.md의 빌드 명령이 --platform linux/amd64로 맞춰져 있다.

  timeout = 900 # 최댓값. 콜드 스타트가 수 GB짜리 이미지를 먼저 내려받는다.

  # Lambda에서 메모리는 CPU 다이얼이기도 하고, 이 잡은 순수 CPU 추론이다. 1GB로 낮추면
  # 같은 배치가 몇 배 느려진다. 과금이 밀리초 단위라 크고 짧은 실행과 작고 느린 실행의
  # 비용이 대체로 같으므로, 낮게 잡아서 얻는 것이 없다.
  memory_size = var.memory_mb

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.security_group_id]
  }

  environment {
    variables = {
      # DB_PASSWORD는 여기 없다. Terraform이 넣으면 state에 평문으로 남기 때문에,
      # apply 밖에서 한 번 주입하고 아래 lifecycle이 그 키를 지켜 준다
      # (docs/runbook.md의 "임베딩 파이프라인 > 비밀번호 주입" 참고).
      #
      # 원래는 이것조차 필요 없었다 — RDS IAM 인증으로 비밀번호 자체가 없는 설계였다.
      # SCP가 rds-db:connect를 막아 임시로 되돌린 상태다. 위 IAM 정책 주석 참고.
      DB_HOST = var.db_host
      DB_PORT = tostring(var.db_port)
      DB_NAME = var.db_name
      DB_USER = var.db_username

      S3_BUCKET = var.photo_bucket_name

      # photos.embedding의 vector(n), 그리고 앱의 Photo.EMBEDDING_DIMENSION과 같아야 한다.
      # 모델이 다른 폭을 내놓으면 잡이 첫 배치에서 스스로 멈춘다.
      EMBED_DIM        = tostring(var.embedding_dimension)
      EMBED_BATCH_SIZE = tostring(var.batch_size)
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.vpc_access,
    aws_cloudwatch_log_group.this,
  ]

  lifecycle {
    ignore_changes = [
      # 새 이미지는 같은 태그로 밀고 update-function-code로 반영한다. 그러면 Terraform이
      # 기록해 둔 다이제스트가 곧바로 낡는다. 이게 없으면 이후 모든 plan이 함수를 마지막
      # apply 시점의 이미지로 되돌리려 든다.
      image_uri,

      # 위 environment 블록에 DB_PASSWORD가 없으므로, 이게 없으면 apply 때마다 손으로
      # 넣은 키를 지운다. 키 하나만 무시하므로 DB_HOST 같은 나머지 값은 정상적으로 반영된다.
      #
      # 이래도 refresh는 AWS에서 값을 읽어 state에 기록한다. 즉 비밀번호는 state 파일에
      # 남는다 — Terraform이 넣지 않을 뿐이다. state 버킷은 버저닝이 켜져 있어 한 번 들어간
      # 값은 과거 버전에도 남으니, SCP가 풀려 이 우회로를 걷을 때 비밀번호도 함께 교체한다.
      environment[0].variables["DB_PASSWORD"],
    ]
  }
}

# InvocationType.EVENT 전송 뒤 Lambda 서비스가 같은 작업을 자체 재시도하면 DB outbox의
# attempt/CAS와 별개인 중복 실행 경로가 생긴다. 재시도는 DB 상태를 보고 서버 outbox가 맡고,
# Lambda는 수락한 이벤트를 한 번만 실행한다. 20분 event age는 15분 함수 상한에 큐 지연
# 5분을 더한 값이라, 장시간 적체된 낡은 작업을 뒤늦게 실행하지 않는다.
resource "aws_lambda_function_event_invoke_config" "this" {
  function_name = aws_lambda_function.this.function_name

  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = var.async_event_max_age_seconds
}

# 앱이 실행을 시작할 수 있게 한다. 인스턴스 프로파일이 앱의 유일한 신원이므로,
# POST /api/v1/galleries/{id}/embeddings/run 이 동작하려면 이 정책이 있어야 한다.
data "aws_iam_policy_document" "app_invoke" {
  statement {
    sid       = "InvokeEmbedder"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.this.arn]
  }
}

resource "aws_iam_role_policy" "app_invoke" {
  name   = "invoke-embedder"
  role   = var.app_role_name
  policy = data.aws_iam_policy_document.app_invoke.json
}

# 앱이 부팅할 때 다른 설정과 함께 읽는다(app.embedding.function-name).
# 이 값이 없으면 앱은 기동은 하되 실행 요청에 503으로 답한다 — 로컬에는 함수가 없는 것이
# 정상이라 기동을 막지 않도록 그렇게 만들어져 있다.
resource "aws_ssm_parameter" "function_name" {
  name  = "${var.parameter_prefix}/app.embedding.function-name"
  type  = "String"
  value = aws_lambda_function.this.function_name
}
