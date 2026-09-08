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

variable "interface_endpoint_subnet_indexes" {
  description = <<-EOT
    bedrock-runtime 인터페이스 엔드포인트의 ENI를 둘 DB 서브넷 인덱스. 기본은 한 AZ([0]) —
    ENI 하나당 시간당 과금(월 약 $11)이고 앱 EC2·RDS도 단일 AZ다. 다른 AZ의 Lambda는 AZ를 건너
    붙어 동작하지만 그 AZ 장애 때 함께 멈춘다. 두 AZ로 늘리려면 [0, 1].
  EOT
  type        = list(number)
  default     = [0]

  validation {
    condition     = length(var.interface_endpoint_subnet_indexes) >= 1 && alltrue([for i in var.interface_endpoint_subnet_indexes : i >= 0 && i < 2])
    error_message = "interface_endpoint_subnet_indexes는 0 또는 1을 하나 이상 담아야 합니다 (DB 서브넷은 AZ당 하나, 총 2개)."
  }
}
