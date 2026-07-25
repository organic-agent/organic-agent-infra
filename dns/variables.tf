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
