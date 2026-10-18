variable "name_prefix" {
  description = "리소스 이름 접두사 (예: wes-dev)"
  type        = string
}

variable "domain_name" {
  description = "이미지 전용 주소(예: img-dev.easyselect.kr). 웹과 같은 상위 도메인이어야 SameSite=Lax 쿠키가 실린다"
  type        = string
}

variable "zone_id" {
  description = "domain_name 레코드와 인증서 검증 레코드를 만들 Route53 존"
  type        = string
}

variable "cookie_domain" {
  description = "앱이 Set-Cookie 에 쓰는 Domain(웹·API·이미지 주소의 공통 상위 도메인, 예: easyselect.kr)"
  type        = string
}

variable "bucket_id" {
  description = "원점 사진 버킷 이름(modules/storage). 이 모듈이 버킷 정책을 소유한다 — 이 배포만 GetObject"
  type        = string
}

variable "bucket_arn" {
  description = "원점 사진 버킷 ARN"
  type        = string
}

variable "bucket_regional_domain_name" {
  description = "원점 사진 버킷의 리전 도메인(<bucket>.s3.<region>.amazonaws.com)"
  type        = string
}

variable "path_prefix" {
  description = <<-EOT
    주소 앞 환경 접두(dev "d", 운영 ""). dev·운영 쿠키가 같은 상위 도메인에 놓여도 경로가 겹치지 않게 한다.
    접두가 있으면 뷰어 요청 함수가 떼어 내고 원점(previews/…)으로 보낸다.
  EOT
  type        = string
  default     = ""
}

variable "public_key_pem" {
  description = "쿠키 서명 공개키(PEM). 개인키는 Terraform 밖에서 만들어 SSM SecureString(<parameter_prefix>/app.storage.preview-cdn.private-key)에 둔다"
  type        = string
}

variable "parameter_prefix" {
  description = "앱이 읽는 SSM 프리픽스 — app.storage.preview-cdn.* (주소·접두·키 ID·쿠키 도메인)를 이 아래에 만든다"
  type        = string
}

variable "price_class" {
  description = "CloudFront 가격 등급. 사용자가 한국이라 아시아를 포함하는 200(가장 비싼 남미·호주 일부 제외)"
  type        = string
  default     = "PriceClass_200"
}

variable "cache_max_age_seconds" {
  description = "미리보기 응답의 Cache-Control max-age. 미리보기는 한 번 만들면 바뀌지 않으니(키가 UUID) 1년 immutable"
  type        = number
  default     = 31536000
}
