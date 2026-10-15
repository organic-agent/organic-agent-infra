variable "name_prefix" {
  description = "리소스 이름 접두사 (예: wes-dev)"
  type        = string
}

variable "ami_id" {
  description = "앱 서버 AMI (modules/compute 의 ami_id)"
  type        = string
}

variable "instance_type" {
  description = "앱 서버 크기"
  type        = string
  default     = "t4g.micro"
}

variable "key_name" {
  description = "비상용 SSH 키 페어 (modules/compute 의 key_name)"
  type        = string
}

variable "instance_profile_name" {
  description = "앱 서버 인스턴스 프로파일 (modules/compute 의 instance_profile_name)"
  type        = string
}

variable "security_group_id" {
  description = "앱 서버 보안 그룹"
  type        = string
}

variable "subnet_ids" {
  description = "앱 서버를 놓을 퍼블릭 서브넷 — 가용 영역 둘에 나눠 둔다"
  type        = list(string)
}

variable "target_group_arn" {
  description = "ALB 대상 그룹 — ASG 가 서버를 스스로 등록·해제한다"
  type        = string
}

variable "bundle_bucket" {
  description = "배포 묶음 버킷 (modules/app-release)"
  type        = string
}

variable "image_tag_parameter" {
  description = "지금 배포된 이미지 태그 SSM 파라미터 (modules/app-release)"
  type        = string
}

variable "deploy_role_name" {
  description = "서버 저장소 CD 역할 — standby·대수 조정 권한을 붙인다"
  type        = string
}

variable "min_size" {
  description = "최소 대수 — 배포·한 대 장애에도 다른 서버가 받으려면 2"
  type        = number
  default     = 2
}

variable "max_size" {
  description = "최대 대수 — DB 연결 예산(서버당 사용자 풀 6, 서버 저장소 #313 03 §2)"
  type        = number
  default     = 3
}

variable "target_cpu_percent" {
  description = "평균 CPU 목표(%) — 넘으면 늘리고 한참 밑돌면 줄인다"
  type        = number
  default     = 50
}

variable "health_check_grace_seconds" {
  description = "새 서버를 ALB 헬스로 판단하기 전 유예(초) — 첫 부팅(도커 설치·이미지·JVM)보다 길게"
  type        = number
  default     = 600
}

variable "instance_warmup_seconds" {
  description = "새 서버의 CPU 를 늘리기 판단에 넣기 전 시간(초)"
  type        = number
  default     = 300
}
