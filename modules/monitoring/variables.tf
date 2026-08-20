variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "subnet_id" {
  description = "인스턴스를 띄울 퍼블릭 서브넷"
  type        = string
}

variable "security_group_id" {
  description = "인스턴스에 붙일 보안 그룹 ID (modules/security의 monitoring SG)"
  type        = string
}

variable "instance_type" {
  description = "EC2 인스턴스 타입 (arm64 — AMI 필터가 arm64 전용)"
  type        = string
}

variable "key_name" {
  description = "비상용 SSH 키 페어 이름 (앱 서버와 공유)"
  type        = string
}

variable "zone_id" {
  description = "A 레코드를 넣을 Route53 호스티드 존 ID"
  type        = string
}

variable "zone_name" {
  description = "호스티드 존 도메인 (예: easyselect.kr)"
  type        = string
}

variable "subdomain" {
  description = "Grafana 접속용 서브도메인 (예: monitoring)"
  type        = string
}

variable "app_parameter_prefix" {
  description = "앱이 읽는 SSM 프리픽스 (예: /wes/prod). 여기에 Loki push URL을 기록한다"
  type        = string
}

variable "monitoring_parameter_prefix" {
  description = "모니터링 서버 전용 SSM 프리픽스 (예: /wes/monitoring). Grafana admin 비밀번호가 여기 있고, 이 인스턴스 롤만 읽는다"
  type        = string
}

variable "loki_port" {
  description = "Loki push 수신 포트"
  type        = number
  default     = 3100
}

variable "loki_retention" {
  description = "Loki 로그 보관 기간 (Loki duration 표기, 예: 168h = 7일)"
  type        = string
  default     = "168h"
}

variable "loki_image" {
  description = "Loki 컨테이너 이미지 (태그 고정)"
  type        = string
  default     = "grafana/loki:3.5.3"
}

variable "grafana_image" {
  description = "Grafana 컨테이너 이미지 (태그 고정)"
  type        = string
  default     = "grafana/grafana:12.1.1"
}

variable "caddy_image" {
  description = "Caddy 컨테이너 이미지 (태그 고정)"
  type        = string
  default     = "caddy:2.10.0"
}
