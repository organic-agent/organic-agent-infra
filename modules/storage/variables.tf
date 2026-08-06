variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "parameter_prefix" {
  description = "SSM 파라미터 프리픽스 (예: /wes/prod) — app.storage.bucket을 이 아래에 생성"
  type        = string
}

variable "app_role_name" {
  description = "버킷 접근 권한을 붙일 앱 인스턴스 롤 이름"
  type        = string
}

variable "web_origins" {
  description = <<-EOT
    버킷에 직접 PUT/GET 하는 브라우저 오리진. scheme://host[:port] 형태여야 하고 끝에
    슬래시를 붙이면 매칭되지 않는다. 앱의 cors.allowed-origins와 같은 목록이어야 하며,
    루트 스택이 그 SSM 파라미터를 그대로 읽어 넘긴다.
  EOT
  type        = list(string)

  validation {
    condition     = alltrue([for o in var.web_origins : can(regex("^https?://[^/]+$", o))])
    error_message = "각 오리진은 경로나 끝 슬래시 없는 scheme://host[:port] 형태여야 합니다."
  }
}
