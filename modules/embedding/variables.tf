variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "parameter_prefix" {
  description = "SSM 파라미터 프리픽스 (예: /wes/prod) — app.embedding.function-name을 이 아래에 생성"
  type        = string
}

variable "subnet_ids" {
  description = "Lambda ENI가 생길 서브넷. RDS와 같은 DB 서브넷이어야 하고, S3 게이트웨이 엔드포인트가 걸려 있어야 한다."
  type        = list(string)
}

variable "security_group_id" {
  description = "Lambda ENI에 붙일 보안 그룹 (RDS 보안 그룹이 이걸 인그레스 소스로 받아야 한다)"
  type        = string
}

variable "app_role_name" {
  description = "Lambda 호출 권한을 붙일 앱 인스턴스 롤 이름"
  type        = string
}

variable "photo_bucket_name" {
  description = "원본 사진 버킷 이름"
  type        = string
}

variable "photo_bucket_arn" {
  description = "원본 사진 버킷 ARN (읽기 권한 대상)"
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
  description = "RDS 리소스 ID(db-XXXX). rds-db:connect 정책의 ARN에 들어간다."
  type        = string
}

variable "db_username" {
  description = <<-EOT
    Lambda가 IAM 인증으로 접속할 DB 사용자. 마스터 계정이 아니다 — 마스터는 rds_iam을
    받을 수 없고, 이 잡에 필요한 권한은 photos 테이블의 SELECT/UPDATE뿐이다.
    DB 안에 이 사용자를 만드는 것은 Terraform 밖의 수동 작업이다(docs/runbook.md).
  EOT
  type        = string
  default     = "embedder"
}

variable "image_tag" {
  description = <<-EOT
    ECR에 올라간 임베더 이미지 태그. 리포지토리에 이 태그가 이미 있어야 한다 —
    이미지 없는 ECR을 상대로는 Lambda가 만들어지지 않는다. 첫 apply 순서는
    docs/deploy-order.md 참고.
  EOT
  type        = string
  default     = "latest"
}

variable "memory_mb" {
  description = <<-EOT
    Lambda 메모리. Lambda에서 이 값은 CPU 할당량이기도 하고 이 잡은 순수 CPU 추론이라,
    3GB 아래로 내리면 같은 작업이 몇 배 느려진다. 과금이 밀리초 단위라 총비용은 거의 같다.
  EOT
  type        = number
  default     = 3008
}

variable "batch_size" {
  description = "모델에 한 번에 넣는 사진 수. 크게 잡을수록 메모리를 더 쓴다."
  type        = number
  default     = 8
}

variable "embedding_dimension" {
  description = <<-EOT
    임베딩 폭. 앱의 Flyway 마이그레이션이 만드는 vector(n) 컬럼, Photo.EMBEDDING_DIMENSION과
    셋이 같아야 한다. 768은 DINOv2-base다. 여기만 바꾸면 모델이 아니라 DB가 쓰기를 거절한다.
  EOT
  type        = number
  default     = 768
}
