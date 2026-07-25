variable "name_prefix" {
  description = "리소스 이름 접두사 (예: wes-oauth-test)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR 블록"
  type        = string
}

variable "azs" {
  description = "서브넷을 분산 배치할 가용 영역 (정확히 2개)"
  type        = list(string)

  validation {
    condition     = length(var.azs) == 2
    error_message = "가용 영역은 정확히 2개여야 합니다 (ALB와 RDS 서브넷 그룹 모두 AZ 2개가 필요함)."
  }
}

variable "public_subnet_cidrs" {
  description = "퍼블릭 서브넷 CIDR 블록, AZ당 1개"
  type        = list(string)
}

variable "db_subnet_cidrs" {
  description = "데이터베이스 서브넷 CIDR 블록, AZ당 1개"
  type        = list(string)
}
