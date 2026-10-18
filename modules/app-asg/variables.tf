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
  # 3 → 2(서버 저장소 #313 10-17 A-4a-3a): 자동 늘리기로 3대째가 9분 만에 왔지만 처리량은 +4~11% — 3대째부터 DB(RDS CPU 80%·풀 6)가
  # 막았다. 늘리기 대신 2대가 받는다. ASG 자체는 고장 서버 교체·spot 회수 뒤 다시 띄우기·롤링 배포 때문에 둔다.
  description = "최대 대수 — 2면 늘리기 없음(min 과 같음)"
  type        = number
  default     = 2
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

variable "spot_enabled" {
  description = "on-demand 바닥 + 나머지 spot 으로 섞을지(서버 저장소 #313 10-17: OD 1 + spot 1). false 면 시작 템플릿 하나(전부 on-demand)"
  type        = bool
  default     = false
}

variable "on_demand_base_capacity" {
  description = "spot 을 섞을 때 늘 on-demand 로 둘 대수 — spot 이 한꺼번에 회수돼도 이만큼은 남는다"
  type        = number
  default     = 1
}

variable "spot_instance_types" {
  # 메모리 2GB 이상인 t4g 만 — 시작 템플릿이 무제한 크레딧(t 계열 전용)이고, micro 는 메모리 관문(H5)에서 막혔다.
  description = "spot 후보 크기 — 비우면 instance_type 하나"
  type        = list(string)
  default     = []
}
