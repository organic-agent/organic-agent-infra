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

variable "db_password_version" {
  description = "SSM 비밀번호 변경 후 RDS에 반영하려면 이 값을 올릴 것"
  type        = number
  default     = 1
}

variable "github_repository" {
  description = "CD가 돌아가는 서버 저장소 (owner/repo) — GitHub OIDC 배포 롤의 신뢰 조건에 사용"
  type        = string
  default     = "organic-agent/organic-agent-server"
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

# --- 임베딩 파이프라인 ---

variable "embedder_db_username" {
  description = <<-EOT
    임베딩 Lambda가 IAM 인증으로 붙을 DB 사용자. 마스터 계정이 아니다 — 마스터는 rds_iam을
    받을 수 없고, 이 잡에 필요한 권한은 photos 테이블의 SELECT/UPDATE뿐이다.
    DB 안에 사용자를 만드는 것은 Terraform 밖의 수동 작업이다 (docs/runbook.md).
  EOT
  type        = string
  default     = "embedder"
}

variable "embedder_image_tag" {
  description = "ECR에 올라간 임베더 이미지 태그. 이 태그가 이미 있어야 Lambda가 만들어진다 (docs/deploy-order.md)."
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
  description = "임베딩 폭. 앱의 vector(n) 컬럼·Photo.EMBEDDING_DIMENSION과 셋이 같아야 한다. 768은 DINOv2-base."
  type        = number
  default     = 768
}
