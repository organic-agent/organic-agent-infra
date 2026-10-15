variable "name_prefix" {
  description = "리소스 이름 접두사 (예: wes-dev)"
  type        = string
}

variable "aws_region" {
  description = "이미지 태그 파라미터 ARN 을 만드는 리전"
  type        = string
}

variable "parameter_prefix" {
  description = "앱 SSM 프리픽스 — 이미지 태그를 <prefix>/app.deploy.image-tag 에 둔다"
  type        = string
}

variable "instance_role_name" {
  description = "앱 서버 인스턴스 역할 — 이미지 받기·배포 묶음 읽기를 붙인다"
  type        = string
}

variable "deploy_role_name" {
  description = "서버 저장소 CD 역할 — 이미지·배포 묶음 올리기·태그 갱신을 붙인다"
  type        = string
}

variable "keep_images" {
  description = "ECR 에 남기는 최근 이미지 수"
  type        = number
  default     = 10
}
