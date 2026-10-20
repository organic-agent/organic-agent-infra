variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "subnet_ids" {
  description = "DB 서브넷 그룹용 서브넷 ID (2개 AZ에 걸쳐 있어야 함)"
  type        = list(string)
}

variable "security_group_id" {
  description = "RDS 인스턴스에 붙일 보안 그룹 ID"
  type        = string
}

variable "parameter_prefix" {
  description = "SSM 파라미터 프리픽스 (예: /wes/dev) — url/username 파라미터를 이 아래에 생성"
  type        = string
}

variable "password_ssm_parameter_arn" {
  description = "마스터 비밀번호가 들어있는 SSM SecureString 파라미터의 ARN (Terraform 밖에서 관리)"
  type        = string
}

variable "password_wo_version" {
  description = "변경된 SSM 비밀번호를 RDS에 반영하려면 이 값을 올릴 것 (write-only 인자 버전)"
  type        = number
  default     = 1
}

variable "instance_class" {
  description = "RDS 인스턴스 클래스"
  type        = string
  default     = "db.t4g.micro"
}

variable "shared_buffers" {
  description = "shared_buffers(8KB 페이지 수 또는 RDS 식). null이면 기본 파라미터 그룹 그대로 — 주면 전용 그룹을 만들어 고정한다(#136). 식 예: \"{DBInstanceClassMemory/131072}\" = 메모리의 6.25% — 클래스를 바꾸면 값이 따라가 큰 값이 작은 서버에 남아 DB 가 못 뜨는 일이 없다"
  type        = string
  default     = null
}

variable "backup_retention_period" {
  description = "자동 백업 보관 일수. 0이면 자동 백업 없음(특정 시점 복구 불가). 0 ↔ 0 아님으로 바꾸면 RDS 가 잠깐 멈춘다(#139)"
  type        = number
  default     = 0
}

variable "deletion_protection" {
  description = "삭제 보호(#139)"
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "지울 때 마지막 스냅샷을 건너뛸지. false 면 <name_prefix>-db-final 로 남긴다(#139)"
  type        = bool
  default     = true
}

variable "engine_version" {
  description = "PostgreSQL 엔진 버전"
  type        = string
  default     = "16.14"
}

variable "allocated_storage" {
  description = "스토리지 크기(GB) (gp3 최소값은 20)"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "초기 데이터베이스 이름"
  type        = string
}

variable "db_username" {
  description = "마스터 계정명"
  type        = string
}
