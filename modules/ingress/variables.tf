variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "vpc_id" {
  description = "타깃 그룹을 만들 VPC"
  type        = string
}

variable "public_subnet_ids" {
  description = "ALB용 퍼블릭 서브넷 (AZ 2개)"
  type        = list(string)
}

variable "security_group_id" {
  description = "ALB에 붙일 보안 그룹 ID"
  type        = string
}

variable "zone_id" {
  description = "레코드를 생성할 Route53 호스티드 존 ID"
  type        = string
}

variable "zone_name" {
  description = "호스티드 존 이름, 앱 FQDN을 만들 때 사용 (예: easyselect.kr)"
  type        = string
}

variable "subdomain" {
  description = "앱 레코드용 서브도메인 (예: oauth-test)"
  type        = string
}

variable "instance_id" {
  description = "타깃 그룹에 등록할 EC2 인스턴스 ID. null 이면 붙이지 않는다 — ASG 가 스스로 등록하는 환경"
  type        = string
  default     = null
}

variable "app_port" {
  description = "애플리케이션이 리슨하는 포트"
  type        = number
}

variable "health_check_path" {
  description = "타깃 그룹 헬스체크 HTTP 경로"
  type        = string
}

# 헬스체크·대상 그룹 손잡이. 기본값은 지금 대상 그룹에 걸린 값(2026-10-15 조회: 30초 · 5초 · 3/3 · slow start 0 · 해제 300초)과 같다 —
# 넘기지 않는 스택(운영)은 바뀌지 않는다.
variable "health_check_interval" {
  description = "헬스체크 간격(초)"
  type        = number
  default     = 30
}

variable "health_check_timeout" {
  description = "헬스체크 응답 대기(초)"
  type        = number
  default     = 5
}

variable "healthy_threshold" {
  description = "연속 성공 몇 번이면 healthy"
  type        = number
  default     = 3
}

variable "unhealthy_threshold" {
  description = "연속 실패 몇 번이면 unhealthy"
  type        = number
  default     = 3
}

variable "slow_start_seconds" {
  description = "새 대상에 몫을 0 에서부터 늘리는 시간(초). 0 이면 끔. 대상이 둘 이상일 때만 동작"
  type        = number
  default     = 0
}

variable "deregistration_delay_seconds" {
  description = "대상을 뺄 때 진행 중 요청을 기다리는 시간(초)"
  type        = number
  default     = 300
}
