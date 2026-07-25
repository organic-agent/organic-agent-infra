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
  description = "타깃 그룹에 등록할 EC2 인스턴스 ID"
  type        = string
}

variable "app_port" {
  description = "애플리케이션이 리슨하는 포트"
  type        = number
}

variable "health_check_path" {
  description = "타깃 그룹 헬스체크 HTTP 경로"
  type        = string
}
