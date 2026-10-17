variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "vpc_id" {
  description = "보안 그룹을 생성할 VPC"
  type        = string
}

variable "app_port" {
  description = "애플리케이션이 리슨하는 포트"
  type        = number
}

variable "health_check_port" {
  description = "ALB 헬스체크가 앱 서버의 다른 포트(관리 포트)로 갈 때 그 번호. null 이면 규칙 없음 — 헬스가 app_port 로 간다"
  type        = number
  default     = null
}

variable "db_port" {
  description = "데이터베이스가 리슨하는 포트"
  type        = number
  default     = 5432
}

variable "ssh_allowed_cidr" {
  description = "EC2 인스턴스에 SSH 접속을 허용할 CIDR (본인 IP /32 권장). null이면 SSH 인그레스 규칙을 만들지 않음"
  type        = string
  default     = null
}

variable "loki_port" {
  description = "Loki가 로그 push를 받는 포트 (앱 서버 SG에서만 허용)"
  type        = number
  default     = 3100
}
