variable "name_prefix" {
  description = "리소스 이름 접두사. 함수·ECR 이름은 `<prefix>-embedder` · `<prefix>-score` · `<prefix>-categorize`가 되며 AI 저장소 deploy.sh와 같아야 한다"
  type        = string
}

variable "parameter_prefix" {
  description = "SSM 파라미터 프리픽스 (예: /wes/prod) — app.analysis.{embedder,score,categorize}-function-name과 app.analysis.gpu.enabled를 이 아래에 생성"
  type        = string
}

variable "subnet_ids" {
  description = "Lambda ENI가 생길 서브넷. RDS와 같은 DB 서브넷이어야 하고, S3 게이트웨이·lambda·bedrock-runtime 엔드포인트가 걸려 있어야 한다."
  type        = list(string)
}

variable "security_group_id" {
  description = "Lambda ENI에 붙일 보안 그룹 (RDS 보안 그룹이 이걸 인그레스 소스로 받아야 한다). 셋이 같은 그룹을 쓴다."
  type        = string
}

variable "app_role_name" {
  description = "함수 셋의 호출 권한을 붙일 앱 인스턴스 롤 이름"
  type        = string
}

variable "photo_bucket_name" {
  description = "사진 버킷 이름 (원본과, embedder가 previews/ 아래에 쓰는 미리보기 JPEG)"
  type        = string
}

variable "photo_bucket_arn" {
  description = "사진 버킷 ARN (embedder는 원본 읽기·previews/ 쓰기, score·categorize는 previews/ 읽기)"
  type        = string
}

variable "db_host" {
  description = "RDS 호스트네임"
  type        = string
}

variable "db_port" {
  description = "RDS 포트"
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "데이터베이스 이름"
  type        = string
}

variable "db_resource_id" {
  description = "RDS 리소스 ID(db-XXXX). embedder의 rds-db:connect 정책 ARN에 들어간다 (지금은 SCP에 막혀 있다)."
  type        = string
}

variable "embedder_db_username" {
  description = <<-EOT
    embedder가 붙을 DB 사용자. 마스터 계정이 아니다 — 마스터는 rds_iam을 받을 수 없고, 서버 저장소의
    Flyway 베이스라인이 이 이름의 role이 있으면 photos·photo_analysis의 최소 컬럼만 GRANT 한다
    (EMBEDDER_GRANT_CONTRACT). DB 안에 사용자를 만드는 것은 Terraform 밖의 수동 작업이다 (docs/runbooks/runbook.md).
  EOT
  type        = string
  default     = "embedder"
}

variable "analysis_db_username" {
  description = <<-EOT
    score·categorize가 붙을 DB 사용자. 마스터 계정이 아니고 embedder 계정과도 다르다 — 서버 저장소의
    Flyway 베이스라인이 이 이름의 role이 있으면 photo_analysis·ai_concept_assignments·ai_analysis_jobs
    등에 필요한 GRANT를 건다(PHOTOSELECT_GRANT_CONTRACT). 역시 수동 생성이다 (docs/runbooks/runbook.md).
  EOT
  type        = string
  default     = "photoselect"
}

variable "image_tag" {
  description = <<-EOT
    ECR에 올라간 이미지 태그. 세 리포지토리에 이 태그가 이미 있어야 한다 — 이미지 없는 ECR을
    상대로는 Lambda가 만들어지지 않는다. 첫 apply 순서는 docs/runbooks/deploy-order.md 참고.
  EOT
  type        = string
  default     = "latest"
}

variable "embedder_memory_mb" {
  description = <<-EOT
    embedder Lambda 메모리. Lambda에서 이 값은 CPU 할당량이기도 하고 이 잡은 순수 CPU 추론이라,
    3GB 아래로 내리면 같은 작업이 몇 배 느려진다. 과금이 밀리초 단위라 총비용은 거의 같다.
  EOT
  type        = number
  default     = 3008
}

variable "embedder_batch_size" {
  description = "embedder가 모델에 한 번에 넣는 사진 수. 크게 잡을수록 메모리를 더 쓴다."
  type        = number
  default     = 8
}

variable "embedding_dimension" {
  description = <<-EOT
    임베딩 폭. 앱의 Flyway 마이그레이션이 만드는 vector(n) 컬럼, PhotoAnalysis.EMBEDDING_DIMENSION과
    셋이 같아야 한다. 768은 DINOv3-base다. 여기만 바꾸면 모델이 아니라 DB가 쓰기를 거절한다.
  EOT
  type        = number
  default     = 768
}

variable "embedder_reserved_concurrent_executions" {
  description = "embedder 함수 동시 실행 상한 = 샤드 상한(MAX_SHARDS=32). 갤러리 하나 = 조정자 1 + 샤드 N(사진 150장 단위, 최대 32) 동시 실행이라 이 값 미만이면 샤드가 스로틀되어 라운드가 늘어난다. 샤드는 세션 advisory lock 으로 RDS 커넥션 1개를 끝까지 붙든다 — db.t4g.micro(max_connections 79)에서 평상시 24 + 32 = 56 이 한계 근거. 갤러리 2개가 겹치면 예약 동시성이 두 번째를 대기열에 세워 직렬화한다(커넥션은 넘치지 않는다)."
  type        = number
  default     = 32

  validation {
    condition     = var.embedder_reserved_concurrent_executions >= 1 && var.embedder_reserved_concurrent_executions <= 64
    error_message = "embedder_reserved_concurrent_executions는 1~64 사이여야 합니다 (advisory lock stride 64 = 샤드 인덱스 상한)."
  }
}

variable "score_memory_mb" {
  description = <<-EOT
    score Lambda 메모리(= CPU 할당량). CLIP ViT-L/14(1.7GB) + ARNIQA + torch를 올려 두고 사진마다
    CPU 추론을 하므로 AI 저장소가 6–8GB를 권한다. 실측 전이라 상한 쪽을 기본으로 둔다.
  EOT
  type        = number
  default     = 8192

  validation {
    condition     = var.score_memory_mb >= 3008 && var.score_memory_mb <= 10240
    error_message = "score_memory_mb는 3008~10240 사이여야 합니다 (모델 셋을 올리려면 3GB 이상, Lambda 상한 10GB)."
  }
}

variable "score_ephemeral_storage_mb" {
  description = <<-EOT
    score Lambda의 /tmp 크기. 갤러리의 미리보기 전부(장당 ~200KB)를 먼저 내려받으므로 기본 512MB로는
    2,500장 남짓에서 찬다. 웜 컨테이너는 갤러리마다 하위 폴더를 남기고 지우지 않으므로 여유 있게 잡는다.
    초과분 과금은 GB-초당 소수점 여덟 자리라 호출당 몇 원이 안 된다.
  EOT
  type        = number
  default     = 10240

  validation {
    condition     = var.score_ephemeral_storage_mb >= 512 && var.score_ephemeral_storage_mb <= 10240
    error_message = "score_ephemeral_storage_mb는 512~10240 사이여야 합니다 (Lambda 허용 범위)."
  }
}

variable "score_reserved_concurrent_executions" {
  description = "score 함수 동시 실행 상한 = 샤드 상한(MAX_SHARDS=32). 갤러리 하나 = 조정자 1 + 샤드 N(사진 150장 단위, 최대 32) 동시 실행이라 이 값 미만이면 샤드가 스로틀되어 라운드가 늘어난다(2 일 때 822장 = 4 샤드 2 라운드 14분, 8 이면 6분). 32 면 7,200장이 샤드당 225장으로 한 라운드(≈ 11분). RDS 커넥션 근거는 embedder 변수와 같다(embedder → score 는 체인이라 겹치지 않는다)."
  type        = number
  default     = 32

  validation {
    condition     = var.score_reserved_concurrent_executions >= 1 && var.score_reserved_concurrent_executions <= 64
    error_message = "score_reserved_concurrent_executions는 1~64 사이여야 합니다 (advisory lock stride 64 = 샤드 인덱스 상한)."
  }
}

variable "categorize_memory_mb" {
  description = "categorize Lambda 메모리. torch 없이 벡터·거리행렬(7,000장에 ~200MB)만 들어 2–3GB면 넉넉하다."
  type        = number
  default     = 3008

  validation {
    condition     = var.categorize_memory_mb >= 1024 && var.categorize_memory_mb <= 10240
    error_message = "categorize_memory_mb는 1024~10240 사이여야 합니다."
  }
}

variable "categorize_ephemeral_storage_mb" {
  description = "categorize Lambda의 /tmp 크기. 그룹 대표 사진 몇 장만 내려받으므로 기본값으로 충분하다."
  type        = number
  default     = 512

  validation {
    condition     = var.categorize_ephemeral_storage_mb >= 512 && var.categorize_ephemeral_storage_mb <= 10240
    error_message = "categorize_ephemeral_storage_mb는 512~10240 사이여야 합니다 (Lambda 허용 범위)."
  }
}

variable "categorize_reserved_concurrent_executions" {
  description = "categorize 함수 동시 실행 상한. 갤러리 한 번에 수 초 + Bedrock 몇 번이라 score와 같은 값이면 체인이 밀리지 않는다."
  type        = number
  default     = 2

  validation {
    condition     = var.categorize_reserved_concurrent_executions >= 1 && var.categorize_reserved_concurrent_executions <= 10
    error_message = "categorize_reserved_concurrent_executions는 1~10 사이여야 합니다."
  }
}

variable "async_event_max_age_seconds" {
  description = "비동기 invoke 이벤트의 최대 대기 수명(셋 공통). 900초 함수 상한과 짧은 큐 지연을 포함한다."
  type        = number
  default     = 1200

  validation {
    condition     = var.async_event_max_age_seconds >= 900 && var.async_event_max_age_seconds <= 21600
    error_message = "async_event_max_age_seconds는 900초 함수 상한 이상, Lambda 허용 상한 21600초 이하여야 합니다."
  }
}

variable "bedrock_model_id" {
  description = <<-EOT
    categorize가 그룹 이름을 지을 때 부르는 Bedrock 모델(추론 프로필) ID. 서울 온디맨드에 Sonnet이 없어
    `global.` 크로스 리전 프로필을 쓴다 — 대표 사진이 국외로 나간다(AI 저장소 categorize/llm.py).
    함수 환경변수 BEDROCK_MODEL_ID와 실행 롤의 InvokeModel 대상이 이 값에서 함께 나온다.
    확인: aws bedrock list-inference-profiles --region ap-northeast-2
  EOT
  type        = string
  default     = "global.anthropic.claude-sonnet-4-6"

  validation {
    condition     = can(regex("^(global|us|eu|apac|jp|au|ca)\\.[a-z0-9.-]+(:[0-9]+)?$", var.bedrock_model_id))
    error_message = "bedrock_model_id는 `global.`·`apac.` 같은 크로스 리전 프로필 ID여야 합니다 (예: global.anthropic.claude-sonnet-4-6). 기반 모델 ID를 직접 주면 IAM 대상이 맞지 않습니다."
  }
}

variable "gpu_score_enabled" {
  description = "SSM app.analysis.gpu.enabled 값. wes가 점수 계산을 GPU 워커 풀에 맡길지(true) score Lambda만 쓸지(false). 워커 풀(PR-3c)이 올라오기 전에는 false"
  type        = bool
  default     = false
}
