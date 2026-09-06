variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "zone_name" {
  description = "Route53 호스티드 존 도메인"
  type        = string
  default     = "easyselect.kr"
}

variable "subdomain" {
  description = "API 서버용 서브도메인"
  type        = string
  default     = "api"
}

variable "ssh_allowed_cidr" {
  description = "EC2 인스턴스에 SSH 접속을 허용할 CIDR (본인 IP /32 권장). null이면 22번 포트 규칙 자체를 만들지 않음 — 평소엔 SSM Session Manager 사용, 필요할 때만 값 지정"
  type        = string
  default     = null
}

# 퍼블릭 키는 비밀 아님 — 팀원 누구나 plan/apply 할 수 있게 커밋해둠.
variable "ssh_public_key" {
  description = "EC2 키 페어(wes-aws-key)로 등록할 SSH 퍼블릭 키"
  type        = string
  default     = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCtn/PIssH3P2nIznmwHpNJqdLqD8SmQt3NT1qy7+0KgjGM8MDXnv7z+S3UawTCOyow1OdGEkQ3Oe+6P1Ge9S0qcvZjmTVJHpWov/tNmwR42Z4wgc/b5s753zpvtEmvfFtMC6LANoEOHk0mbUQ4dqANQ4ny0kOESAQYK19vr+UCjEIPAaTQLoWr33xayULlV3IJz29jjAnjbG9PTfcD9c3Zm/ihtO42Z7wAeYQrgMzAjnmn7m0MwN/aKS9Q4OQm25rRRhl27kQC9AyxqQM/JpMJxUeUJla/mawhRsLI8+Fxpr/Bj9J2KIpYEMU1ylfcM8QzW8tqEsGqIsZJieAuSHCF wes-aws-key"
}

variable "instance_type" {
  description = "EC2 인스턴스 타입 (arm64)"
  type        = string
  default     = "t4g.micro"
}

variable "app_port" {
  description = "Spring Boot 앱이 리슨하는 포트"
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "ALB 헬스체크 경로"
  type        = string
  default     = "/actuator/health"
}

# --- 백오피스 내부 접근 (WES-253) ---

variable "admin_subdomain" {
  description = "Tailscale 내부에서만 접근할 백오피스 서브도메인"
  type        = string
  default     = "admin"
}

variable "admin_instance_type" {
  description = "백오피스와 관리자 API를 함께 실행할 EC2 타입 (arm64, 최소 2GiB 메모리)"
  type        = string
  default     = "t4g.small"

  validation {
    condition     = !contains(["t4g.nano", "t4g.micro"], var.admin_instance_type)
    error_message = "백오피스와 Spring Boot 관리자 API를 함께 실행하므로 t4g.nano/micro는 허용하지 않습니다. 최소 t4g.small을 사용하세요."
  }
}

variable "admin_app_port" {
  description = "백오피스 앱이 localhost에서 리슨할 포트"
  type        = number
  default     = 8080
}

variable "admin_api_port" {
  description = "관리자 API가 컨테이너와 localhost health에서 리슨할 포트. SG/Caddy에는 열지 않는다."
  type        = number
  default     = 8081

  validation {
    condition     = var.admin_api_port >= 1024 && var.admin_api_port <= 65535 && var.admin_api_port != var.admin_app_port
    error_message = "admin_api_port는 1024~65535 사이이며 BackOffice 포트와 달라야 합니다."
  }
}

variable "admin_proxy_https_port" {
  description = "Caddy가 localhost에서 TLS를 종료하고 Tailscale Serve가 전달할 포트"
  type        = number
  default     = 8443
}

variable "admin_tailscale_hostname" {
  description = "백오피스 전용 서버의 tailnet 호스트 이름"
  type        = string
  default     = "wes-admin"
}

variable "admin_tailscale_ipv4" {
  description = "첫 apply 후 확인한 wes-admin의 Tailscale IPv4. null이면 admin DNS A 레코드를 만들지 않는다."
  type        = string
  default     = "100.88.250.104"

  validation {
    condition     = var.admin_tailscale_ipv4 == null ? true : try(cidrhost("${var.admin_tailscale_ipv4}/10", 0) == "100.64.0.0", false)
    error_message = "admin_tailscale_ipv4는 Tailscale CGNAT 대역(100.64.0.0/10)의 IPv4여야 합니다."
  }
}

variable "admin_tailscale_auth_parameter_name" {
  description = "tag:wes-admin 일회용 auth key를 담을 수동 생성 SecureString. 앱이 읽는 /wes/prod 밖에 둔다."
  type        = string
  default     = "/wes/admin/tailscale-auth-key"

  validation {
    condition     = startswith(var.admin_tailscale_auth_parameter_name, "/") && !startswith(var.admin_tailscale_auth_parameter_name, "${var.parameter_prefix}/")
    error_message = "admin_tailscale_auth_parameter_name은 /로 시작하고 앱 parameter_prefix 밖에 있어야 합니다."
  }
}

variable "admin_tailscale_auth_kms_key_arn" {
  description = "Tailscale auth key SecureString의 고객 관리형 KMS 키 ARN. 기본 aws/ssm 키이면 null."
  type        = string
  default     = null
}

variable "admin_parameter_prefix" {
  description = "관리자 API만 읽는 SSM 파라미터 프리픽스. 공개 앱 /wes/prod와 분리한다."
  type        = string
  default     = "/wes/admin-api/prod"

  validation {
    condition = (
      startswith(var.admin_parameter_prefix, "/") &&
      !endswith(var.admin_parameter_prefix, "/") &&
      var.admin_parameter_prefix != var.parameter_prefix &&
      !startswith(var.admin_parameter_prefix, "${var.parameter_prefix}/")
    )
    error_message = "admin_parameter_prefix는 /로 시작하고 끝 슬래시가 없어야 하며 공개 앱 parameter_prefix와 분리되어야 합니다."
  }
}

variable "admin_runtime_kms_key_arn" {
  description = "관리자 API SecureString에 고객 관리형 KMS 키를 쓰는 경우의 ARN. 기본 aws/ssm 키이면 null."
  type        = string
  default     = null
}

variable "admin_db_username" {
  description = "관리자 API 전용 PostgreSQL 런타임 계정. Flyway/DDL 권한은 주지 않고 수동 생성한다."
  type        = string
  default     = "wes_admin_api"
}

variable "db_name" {
  description = "초기 PostgreSQL 데이터베이스 이름"
  type        = string
  default     = "wes_db"
}

variable "db_username" {
  description = "PostgreSQL 마스터 계정명 ('user'는 PostgreSQL 예약어라 RDS가 거부함)"
  type        = string
  default     = "wes_admin"
}

variable "parameter_prefix" {
  description = "이 환경의 SSM 파라미터 프리픽스 (앱이 이 경로 아래를 직접 읽음)"
  type        = string
  default     = "/wes/prod"
}

variable "local_parameter_prefix" {
  description = "로컬 개발(local 프로필)용 SSM 파라미터 프리픽스. dev 버킷 이름(app.storage.bucket)을 이 아래에 쓴다"
  type        = string
  default     = "/wes/local"
}

variable "local_web_origins" {
  description = <<-EOT
    dev 버킷의 CORS 허용 오리진 — 로컬 프론트 주소들. 운영 버킷과 달리 SSM에서 읽지 않는다.
    앱의 local 프로필 cors.allowed-origins는 yml 고정값(localhost)이라 여기 기본값과 맞춰 둔다.
  EOT
  type        = list(string)
  default     = ["http://localhost:3000", "http://localhost:5173"]
}

variable "db_password_version" {
  description = "SSM 비밀번호 변경 후 RDS에 반영하려면 이 값을 올릴 것"
  type        = number
  default     = 1
}

variable "github_repository" {
  description = "CD가 돌아가는 서버 저장소 (owner/repo) — GitHub OIDC 배포 롤의 신뢰 조건에 사용"
  type        = string
  default     = "organic-agent/organic-agent-server"

  validation {
    condition     = var.github_repository == "organic-agent/organic-agent-server"
    error_message = "github_repository는 운영 서버 저장소의 정확한 owner/name이어야 합니다."
  }
}

variable "github_repository_owner_id" {
  description = "organic-agent GitHub organization의 immutable owner ID"
  type        = string
  default     = "299031009"

  validation {
    condition     = var.github_repository_owner_id == "299031009"
    error_message = "github_repository_owner_id는 organic-agent의 immutable owner ID여야 합니다."
  }
}

variable "github_repository_id" {
  description = "organic-agent-server의 immutable GitHub repository ID"
  type        = string
  default     = "1297201474"

  validation {
    condition     = var.github_repository_id == "1297201474"
    error_message = "github_repository_id는 organic-agent-server의 immutable repository ID여야 합니다."
  }
}

variable "admin_github_oidc_subject" {
  description = "백오피스 main의 immutable GitHub OIDC sub — 전용 배포 롤은 이 단일 값만 신뢰"
  type        = string
  default     = "repo:organic-agent@299031009/organic-agent-backoffice@1344578659:ref:refs/heads/main"

  validation {
    condition     = var.admin_github_oidc_subject == "repo:organic-agent@299031009/organic-agent-backoffice@1344578659:ref:refs/heads/main"
    error_message = "admin_github_oidc_subject는 backoffice main의 정확한 immutable sub여야 합니다. 이름 기반 값, 와일드카드, 복수 subject는 허용하지 않습니다."
  }
}

variable "admin_github_repository_id" {
  description = "organic-agent-backoffice의 immutable GitHub repository ID"
  type        = string
  default     = "1344578659"

  validation {
    condition     = var.admin_github_repository_id == "1344578659"
    error_message = "admin_github_repository_id는 organic-agent-backoffice의 immutable repository ID여야 합니다."
  }
}

# AI 저장소(organic-agent-ai)는 2026-08-17 생성이라 백오피스처럼 기본 sub가 immutable 형식이다
# (`gh api repos/organic-agent/organic-agent-ai/actions/oidc/customization/sub` 의 sub_claim_prefix).
variable "ai_github_oidc_subject" {
  description = "AI 저장소 main의 immutable GitHub OIDC sub — Lambda 셋 배포 롤(worker_deploy)은 이 단일 값만 신뢰"
  type        = string
  default     = "repo:organic-agent@299031009/organic-agent-ai@1336874708:ref:refs/heads/main"

  validation {
    condition     = var.ai_github_oidc_subject == "repo:organic-agent@299031009/organic-agent-ai@1336874708:ref:refs/heads/main"
    error_message = "ai_github_oidc_subject는 organic-agent-ai main의 정확한 immutable sub여야 합니다. 이름 기반 값, 와일드카드, 복수 subject는 허용하지 않습니다."
  }
}

variable "ai_github_repository_id" {
  description = "organic-agent-ai의 immutable GitHub repository ID"
  type        = string
  default     = "1336874708"

  validation {
    condition     = var.ai_github_repository_id == "1336874708"
    error_message = "ai_github_repository_id는 organic-agent-ai의 immutable repository ID여야 합니다."
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR 블록"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "가용 영역 (2b, 2d는 인스턴스 지원 안돼서 제외 — 지원 안 되는 인스턴스 타입이 많음)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "public_subnet_cidrs" {
  description = "퍼블릭 서브넷 CIDR 목록"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "db_subnet_cidrs" {
  description = "데이터베이스 서브넷 CIDR 목록"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "interface_endpoint_subnet_indexes" {
  description = <<-EOT
    lambda·bedrock-runtime 인터페이스 엔드포인트의 ENI를 둘 DB 서브넷 인덱스. 기본은 두 AZ 모두
    (엔드포인트 둘 × ENI 둘 ≈ 월 $43). [0] 하나로 줄이면 비용이 절반이지만 그 AZ 장애 때 Lambda 셋의
    재호출·체인·Bedrock 호출이 함께 멈춘다.
  EOT
  type        = list(number)
  default     = [0, 1]
}

# --- AI Lambda 셋 (embedder → score → categorize) ---

variable "embedder_db_username" {
  description = <<-EOT
    임베딩 Lambda가 붙을 DB 사용자. 마스터 계정이 아니다 — 마스터는 rds_iam을 받을 수 없고,
    서버의 Flyway 베이스라인이 이 이름의 role에 photos·photo_analysis의 최소 컬럼만 GRANT 한다.
    DB 안에 사용자를 만드는 것은 Terraform 밖의 수동 작업이다 (docs/runbook.md).
  EOT
  type        = string
  default     = "embedder"
}

variable "analysis_db_username" {
  description = <<-EOT
    score·categorize Lambda가 붙을 DB 사용자. 마스터도 임베더 계정도 아니다 — 서버 저장소 Flyway
    베이스라인이 이 이름의 role이 있으면 photo_analysis·ai_concept_assignments·ai_analysis_jobs 등의
    GRANT를 건다(PHOTOSELECT_GRANT_CONTRACT). 역시 수동 생성이다 (docs/runbook.md).
  EOT
  type        = string
  default     = "photoselect"
}

variable "lambda_image_tag" {
  description = "ECR에 올라간 Lambda 셋의 이미지 태그. 세 리포지토리에 이 태그가 이미 있어야 함수가 만들어진다 (docs/deploy-order.md)."
  type        = string
  default     = "latest"
}

variable "embedder_memory_mb" {
  description = "임베딩 Lambda 메모리(= CPU 할당량). 순수 CPU 추론이라 낮추면 몇 배 느려지고 총비용은 그대로다."
  type        = number
  default     = 3008
}

variable "embedder_batch_size" {
  description = "모델에 한 번에 넣는 사진 수"
  type        = number
  default     = 8
}

variable "embedding_dimension" {
  description = "임베딩 폭. 앱의 vector(n) 컬럼·PhotoAnalysis.EMBEDDING_DIMENSION과 셋이 같아야 한다. 768은 DINOv3-base."
  type        = number
  default     = 768
}

variable "score_memory_mb" {
  description = "score Lambda 메모리(= CPU 할당량). CLIP-L + ARNIQA + torch라 AI 저장소가 6–8GB를 권한다. 실측 전이라 상한 쪽."
  type        = number
  default     = 8192
}

variable "score_ephemeral_storage_mb" {
  description = "score Lambda의 /tmp. 갤러리 미리보기 전부(장당 ~200KB)를 먼저 내려받아 기본 512MB로는 2,500장 남짓에서 찬다."
  type        = number
  default     = 10240
}

variable "score_reserved_concurrent_executions" {
  description = "score 함수 동시 실행 상한 = 샤드 상한(MAX_SHARDS=32). score는 갤러리를 샤드(사진 150장 단위, 최대 32)로 나눠 같은 함수를 동시에 띄우므로 이 값 미만이면 샤드가 스로틀되어 라운드가 늘어난다. 상한은 RDS 커넥션(db.t4g.micro 79, 평상시 24 + 샤드 32)이 정한다 — 더 올리려면 RDS 클래스부터."
  type        = number
  default     = 32
}

variable "categorize_memory_mb" {
  description = "categorize Lambda 메모리. torch 없이 거리행렬(7,000장에 ~200MB)만 들어 2–3GB면 넉넉하다."
  type        = number
  default     = 3008
}

variable "categorize_reserved_concurrent_executions" {
  description = "categorize 함수 동시 실행 상한. score와 같은 값이면 체인이 밀리지 않는다."
  type        = number
  default     = 2
}

variable "bedrock_model_id" {
  description = "categorize의 그룹 이름 짓기와 앱(EC2)의 추천 이유·비교샷 판정에 쓰는 Bedrock 모델(크로스 리전 추론 프로필 ID). Lambda 환경변수, Lambda·EC2 실행 롤의 InvokeModel 대상이 여기서 함께 나온다. 앱 설정 app.llm.model-id와 같아야 한다."
  type        = string
  default     = "global.anthropic.claude-sonnet-4-6"
}

# --- 모니터링 (Loki + Grafana) ---

variable "monitoring_subdomain" {
  description = "Grafana 접속용 서브도메인 (EIP 직결, ALB 미경유)"
  type        = string
  default     = "monitoring"
}

variable "monitoring_instance_type" {
  description = "모니터링 EC2 타입 (arm64). t4g.nano(512MiB)는 Grafana+Loki가 OOM 나기 쉬워 micro를 기본으로 둔다"
  type        = string
  default     = "t4g.micro"
}

variable "monitoring_parameter_prefix" {
  description = "모니터링 서버 전용 SSM 프리픽스. Grafana admin 비밀번호(`grafana.admin-password`, SecureString)를 수동 등록한다 — 앱 프리픽스 밖이라 앱이 읽지 못한다"
  type        = string
  default     = "/wes/monitoring"
}

variable "loki_retention" {
  description = "Loki 로그 보관 기간. 20GB 루트 볼륨 안에서 돌게 7일로 둔다"
  type        = string
  default     = "168h"
}

# --- 인프라 CI/CD ---

variable "infra_repository" {
  description = "이 저장소 (owner/repo) — Terraform plan/apply 롤의 OIDC 신뢰 조건에 사용"
  type        = string
  default     = "organic-agent/organic-agent-infra"

  validation {
    condition     = var.infra_repository == "organic-agent/organic-agent-infra"
    error_message = "infra_repository는 운영 인프라 저장소의 정확한 owner/name이어야 합니다."
  }
}

variable "infra_github_repository_id" {
  description = "organic-agent-infra의 immutable GitHub repository ID"
  type        = string
  default     = "1288279318"

  validation {
    condition     = var.infra_github_repository_id == "1288279318"
    error_message = "infra_github_repository_id는 organic-agent-infra의 immutable repository ID여야 합니다."
  }
}

variable "frontend_test_github_oidc_subject" {
  description = "테스트 프론트 main의 immutable GitHub OIDC sub"
  type        = string
  default     = "repo:organic-agent@299031009/organic-agent-test-web@1359048612:ref:refs/heads/main"

  validation {
    condition     = var.frontend_test_github_oidc_subject == "repo:organic-agent@299031009/organic-agent-test-web@1359048612:ref:refs/heads/main"
    error_message = "테스트 프론트 배포는 organic-agent-test-web main의 정확한 immutable subject만 허용합니다."
  }
}

variable "frontend_test_github_repository_id" {
  description = "organic-agent-test-web의 immutable GitHub repository ID"
  type        = string
  default     = "1359048612"

  validation {
    condition     = var.frontend_test_github_repository_id == "1359048612"
    error_message = "테스트 프론트 배포 저장소 ID는 1359048612여야 합니다."
  }
}
