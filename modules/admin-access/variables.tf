variable "name_prefix" {
  description = "백오피스 전용 리소스 이름 접두사"
  type        = string
}

variable "aws_region" {
  description = "인스턴스와 AWS API를 사용할 리전"
  type        = string
}

variable "vpc_id" {
  description = "백오피스 서버 보안 그룹을 생성할 VPC"
  type        = string
}

variable "subnet_id" {
  description = "아웃바운드 인터넷 경로가 있는 서브넷. 서버 보안 그룹에는 인바운드 규칙이 없다."
  type        = string
}

variable "instance_type" {
  description = "백오피스 전용 EC2 인스턴스 타입(arm64)"
  type        = string
}

variable "zone_id" {
  description = "easyselect.kr Route53 hosted zone ID"
  type        = string
}

variable "fqdn" {
  description = "백오피스 커스텀 도메인"
  type        = string
}

variable "tailscale_ipv4" {
  description = "서버가 tailnet에 등록된 뒤 확인한 Tailscale IPv4. null이면 DNS 레코드를 아직 만들지 않는다."
  type        = string
  default     = null

  validation {
    condition     = var.tailscale_ipv4 == null ? true : try(cidrhost("${var.tailscale_ipv4}/10", 0) == "100.64.0.0", false)
    error_message = "tailscale_ipv4는 Tailscale CGNAT 대역(100.64.0.0/10)의 IPv4여야 합니다."
  }
}

variable "tailscale_hostname" {
  description = "tailnet에 표시할 전용 서버 이름"
  type        = string
}

variable "tailscale_auth_parameter_name" {
  description = "tag:wes-admin이 지정된 일회용 Tailscale auth key를 담는 앱 경로 밖 SecureString 파라미터 이름"
  type        = string
}

variable "tailscale_auth_parameter_arn" {
  description = "부트스트랩이 읽을 Tailscale auth key SecureString 파라미터 ARN"
  type        = string
}

variable "tailscale_auth_kms_key_arn" {
  description = "SecureString이 고객 관리형 KMS 키를 쓰는 경우 해당 키 ARN. 기본 aws/ssm 키이면 null."
  type        = string
  default     = null
}

variable "runtime_parameter_prefix_arn" {
  description = "관리자 API만 읽을 SSM Parameter Store prefix ARN"
  type        = string
}

variable "runtime_kms_key_arn" {
  description = "관리자 API SecureString용 고객 관리형 KMS 키 ARN. 기본 aws/ssm 키이면 null."
  type        = string
  default     = null
}

variable "photo_bucket_arn" {
  description = "관리자 API가 원본 조회·교체 업로드·purge에 사용할 사진 버킷 ARN"
  type        = string
}

variable "embedding_function_arn" {
  description = "관리자 API가 재처리를 요청할 임베딩 Lambda ARN"
  type        = string
}

variable "app_port" {
  description = "백오피스 앱이 localhost에서 리슨할 포트"
  type        = number
}

variable "proxy_https_port" {
  description = "Caddy가 localhost에서 TLS를 종료할 포트"
  type        = number
  default     = 8443
}

variable "internal_network_name" {
  description = "BackOffice와 관리자 API 사이에서만 쓰는 외부 라우팅 없는 Docker network"
  type        = string
  default     = "wes-admin-internal"
}

variable "internal_network_subnet" {
  description = "내부 Docker network의 고정 CIDR. IMDS 차단 방화벽의 source 범위로도 사용한다."
  type        = string
  default     = "172.30.0.0/24"

  validation {
    condition     = can(cidrhost(var.internal_network_subnet, 1))
    error_message = "internal_network_subnet은 올바른 IPv4 CIDR이어야 합니다."
  }
}

variable "runtime_network_name" {
  description = "관리자 API만 붙어 RDS·SSM·S3·Lambda와 IMDS에 접근하는 Docker network"
  type        = string
  default     = "wes-admin-runtime"
}

variable "runtime_network_subnet" {
  description = "관리자 API 런타임 Docker network의 고정 CIDR"
  type        = string
  default     = "172.30.1.0/24"

  validation {
    condition     = can(cidrhost(var.runtime_network_subnet, 1))
    error_message = "runtime_network_subnet은 올바른 IPv4 CIDR이어야 합니다."
  }
}

variable "deploy_lock_path" {
  description = "같은 호스트에 배포하는 두 저장소의 SSM 스크립트가 공유할 flock 파일"
  type        = string
  default     = "/var/lock/wes-admin-deploy.lock"

  validation {
    condition     = startswith(var.deploy_lock_path, "/var/lock/")
    error_message = "deploy_lock_path는 /var/lock 아래의 절대 경로여야 합니다."
  }
}

variable "caddy_version" {
  description = "부트스트랩에서 빌드할 Caddy 버전"
  type        = string
  default     = "2.10.2"
}

variable "caddy_route53_version" {
  description = "Caddy Route53 DNS provider 모듈 버전"
  type        = string
  default     = "v1.6.0"
}
