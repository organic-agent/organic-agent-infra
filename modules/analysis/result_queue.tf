# --- 임베더 결과 큐 (wes #286 (m)) ---
#
#   지금:  wes ──50장──▶ embedder ×72 ──(DB 연결 72, 8장마다 INSERT·UPDATE)──▶ RDS
#   전환:  wes ──50장 + 원본 위치──▶ embedder ×72 (VPC 밖, DB 없음) ──8장 = 메시지 1──▶ [결과 큐] ──▶ embedwriter ×≤2 ──(수백 장씩)──▶ RDS
#
# 왜: dev B-1′(업로드 5 × 7,189 + 사용자 200명)에서 임베더 쓰기가 DB 시간의 57%(INSERT 평균 86ms)였고, 업로드 7분 동안 사용자 요청이
# 연결 풀(10)에서 줄을 섰다(최대 193). 쓰는 총량은 같지만 72곳이 동시에 쓰던 것을 1~2곳이 묶어 쓰면 연결 수와 몰림이 준다.
# 메시지 형식은 AI 저장소 embedwriter/README(계약 v1). 진행 판단은 그대로 photo_analysis 행이다 — 결과가 몇 초 늦게 보일 뿐이다.
#
# 두 단계로 켠다: embed_result_queue_enabled(큐·DLQ·ECR·embedder-admin) → writer 이미지 배포 → embedwriter_deployed(writer·트리거·임베더 전환).

locals {
  result_queue_on     = var.embed_result_queue_enabled
  embedwriter_on      = var.embed_result_queue_enabled && var.embedwriter_deployed
  embedwriter_name    = "${var.name_prefix}-embedwriter"
  embedder_admin_name = "${var.name_prefix}-embedder-admin"
}

# writer 가 5번 받고도 못 쓴 메시지. 쓰지 못한 사진은 wes 시간 기반 재배정(3분)이 다시 임베딩하므로 잃지 않는다 — 여기는 원인을 보는 자리다.
resource "aws_sqs_queue" "result_dlq" {
  count = local.result_queue_on ? 1 : 0

  name                      = "${var.name_prefix}-embed-results-dlq"
  message_retention_seconds = 345600
  sqs_managed_sse_enabled   = true
}

# 가시성 360초 = writer 타임아웃(60초)의 6배 — AWS 가 SQS 트리거에 권하는 값(처리 중 메시지가 다시 보이지 않게).
# 보관 1일: 결과가 하루 넘게 쌓이면 이미 wes 가 다시 임베딩했다.
resource "aws_sqs_queue" "result" {
  count = local.result_queue_on ? 1 : 0

  name                       = "${var.name_prefix}-embed-results"
  message_retention_seconds  = 86400
  visibility_timeout_seconds = 360
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.result_dlq[0].arn
    maxReceiveCount     = 5
  })
}

# 배치 임베더가 결과를 넣는다. 기존 인라인 정책에 섞지 않는다(스위치를 켜고 끌 때 정책 문서 전체가 바뀌지 않게).
data "aws_iam_policy_document" "embedder_send_results" {
  count = local.embedwriter_on ? 1 : 0

  statement {
    sid       = "SendEmbedResults"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.result[0].arn]
  }
}

resource "aws_iam_role_policy" "embedder_send_results" {
  count = local.embedwriter_on ? 1 : 0

  name   = "send-embed-results"
  role   = aws_iam_role.this["embedder"].id
  policy = data.aws_iam_policy_document.embedder_send_results[0].json
}

# 결과 큐가 밀리면 wes 가 "아직 안 끝났다"로 보고 재배정 시간(3분) 뒤 다시 보낸다 — 중복 임베딩. 1분을 넘기면 상태로 남긴다.
resource "aws_cloudwatch_metric_alarm" "result_queue_age" {
  count = local.result_queue_on ? 1 : 0

  alarm_name          = "${var.name_prefix}-embed-results-age"
  alarm_description   = "임베더 결과 큐의 가장 오래된 메시지가 60초를 넘었다 — writer 가 임베더를 못 따라간다"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 60
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.result[0].name
  }
}

resource "aws_cloudwatch_metric_alarm" "result_dlq_visible" {
  count = local.result_queue_on ? 1 : 0

  alarm_name          = "${var.name_prefix}-embed-results-dlq"
  alarm_description   = "writer 가 끝내 쓰지 못한 임베더 결과가 DLQ 에 있다"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.result_dlq[0].name
  }
}

# --- embedwriter: 결과 큐 → RDS ---

resource "aws_ecr_repository" "embedwriter" {
  count = local.result_queue_on ? 1 : 0

  name         = local.embedwriter_name
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "embedwriter" {
  count = local.result_queue_on ? 1 : 0

  repository = aws_ecr_repository.embedwriter[0].name
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

resource "aws_iam_role" "embedwriter" {
  count = local.embedwriter_on ? 1 : 0

  name_prefix        = "${local.embedwriter_name}-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "embedwriter_vpc_access" {
  count = local.embedwriter_on ? 1 : 0

  role       = aws_iam_role.embedwriter[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# SQS 트리거는 Lambda 서비스가 큐를 읽어 함수를 부르지만, 권한은 함수의 실행 롤로 확인한다 — 함수가 VPC 안이어도 엔드포인트는 필요 없다.
data "aws_iam_policy_document" "embedwriter" {
  count = local.embedwriter_on ? 1 : 0

  statement {
    sid = "ConsumeEmbedResults"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.result[0].arn]
  }
}

resource "aws_iam_role_policy" "embedwriter" {
  count = local.embedwriter_on ? 1 : 0

  name   = "consume-embed-results"
  role   = aws_iam_role.embedwriter[0].id
  policy = data.aws_iam_policy_document.embedwriter[0].json
}

resource "aws_cloudwatch_log_group" "embedwriter" {
  count = local.embedwriter_on ? 1 : 0

  name              = "/aws/lambda/${local.embedwriter_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "embedwriter" {
  count = local.embedwriter_on ? 1 : 0

  function_name = local.embedwriter_name
  role          = aws_iam_role.embedwriter[0].arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.embedwriter[0].repository_url}:${var.embedwriter_image_tag}"

  # 한 번에 메시지 10개(≈ 80장)를 한 트랜잭션으로 쓴다 — 몇 초면 끝난다. torch 가 없어 메모리는 작게.
  timeout     = 60
  memory_size = 512

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.security_group_id]
  }

  # 임베더와 같은 DB 사용자(embedder) — photo_analysis 벡터 UPSERT 와 photos 미리보기·EXIF 갱신 권한이 이미 있다(wes V15 계약).
  environment {
    variables = merge(local.db_env, local.ssl_env, {
      DB_USER = var.embedder_db_username
    })
  }

  depends_on = [
    aws_iam_role_policy_attachment.embedwriter_vpc_access,
    aws_cloudwatch_log_group.embedwriter,
  ]

  lifecycle {
    # 다른 함수와 같은 이유(main.tf aws_lambda_function.this) — 이미지는 deploy.sh 가, DB_PASSWORD 는 runbook 대로 손으로 넣는다.
    ignore_changes = [image_uri, environment[0].variables["DB_PASSWORD"]]
  }
}

# 메시지를 최대 10개까지, 2초까지 모아 한 번에 넘긴다. 실패한 메시지만 다시(ReportBatchItemFailures) — 한 장이 묶음 전체를 막지 않게.
resource "aws_lambda_event_source_mapping" "embedwriter" {
  count = local.embedwriter_on ? 1 : 0

  event_source_arn                   = aws_sqs_queue.result[0].arn
  function_name                      = aws_lambda_function.embedwriter[0].arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 2
  function_response_types            = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = var.embedwriter_max_concurrency
  }
}

# --- embedder-admin: 관리자 사진 교체 (같은 임베더 이미지, VPC 안) ---
#
# 배치 임베더가 VPC 밖으로 나가면 관리자 사진 교체({jobId, …} — 검증 · 미리보기 · 벡터 · 완료를 한 트랜잭션으로 DB 에 쓴다)가 DB 에 닿지 못한다.
# 같은 이미지·롤로 VPC 안 함수를 하나 더 두고 관리자 앱이 이 함수를 부른다(wes app.analysis.exact-photo-function-name).
# 이미지는 임베더 deploy.sh 가 두 함수에 함께 민다.
resource "aws_cloudwatch_log_group" "embedder_admin" {
  count = local.result_queue_on ? 1 : 0

  name              = "/aws/lambda/${local.embedder_admin_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "embedder_admin" {
  count = local.result_queue_on ? 1 : 0

  function_name = local.embedder_admin_name
  role          = aws_iam_role.this["embedder"].arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.this["embedder"].repository_url}:${var.image_tag}"

  timeout     = 900
  memory_size = local.functions.embedder.memory_mb

  ephemeral_storage {
    size = local.functions.embedder.ephemeral_storage_mb
  }

  reserved_concurrent_executions = var.embedder_admin_reserved_concurrency

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.security_group_id]
  }

  environment {
    variables = local.functions.embedder.environment
  }

  depends_on = [
    aws_iam_role_policy_attachment.vpc_access,
    aws_cloudwatch_log_group.embedder_admin,
  ]

  lifecycle {
    ignore_changes = [image_uri, environment[0].variables["DB_PASSWORD"]]
  }
}

# 관리자 교체는 자기 outbox(관리자 작업 테이블)가 재시도를 맡는다 — Lambda 재시도는 끈다(main.tf 의 다른 함수와 같은 이유).
resource "aws_lambda_function_event_invoke_config" "embedder_admin" {
  count = local.result_queue_on ? 1 : 0

  function_name                = aws_lambda_function.embedder_admin[0].function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = var.async_event_max_age_seconds
}
