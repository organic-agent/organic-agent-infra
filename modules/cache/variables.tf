variable "name_prefix" {
  description = "리소스 이름 접두사 (예: wes-dev)"
  type        = string
}

variable "vpc_id" {
  description = "캐시 보안 그룹을 만들 VPC"
  type        = string
}

variable "subnet_ids" {
  description = "캐시 서브넷 그룹용 사설 서브넷 ID (DB 서브넷과 같은 것을 쓴다)"
  type        = list(string)
}

variable "client_security_group_ids" {
  description = "캐시에 붙을 수 있는 보안 그룹(앱 서버)"
  type        = list(string)
}

variable "parameter_prefix" {
  description = "앱이 읽는 SSM 프리픽스 — spring.data.redis.* 접속 정보를 이 아래에 만든다"
  type        = string
}

variable "node_type" {
  description = "캐시 노드 크기"
  type        = string
  default     = "cache.t4g.micro"
}

variable "engine_version" {
  description = "Valkey 버전"
  type        = string
  default     = "8.0"
}

variable "parameter_group_family" {
  description = "engine_version과 맞는 파라미터 그룹 계열"
  type        = string
  default     = "valkey8"
}

variable "port" {
  description = "캐시 포트"
  type        = number
  default     = 6379
}

variable "apply_immediately" {
  description = "설정 변경을 다음 정비 창이 아니라 바로 반영할지 (dev는 true)"
  type        = bool
  default     = false
}
