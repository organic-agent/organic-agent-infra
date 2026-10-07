variable "name" {
  description = "풀 이름이자 워커 인스턴스의 Name 태그 값(예: wes-score-gpu). 앱 롤의 Start/Stop 조건과 wes app.analysis.gpu.tag가 같은 값을 써야 하고, 롤 이름이 이 값으로 시작하므로 tf_apply의 IAM 울타리(`wes-*`) 안이어야 한다"
  type        = string
}

variable "parameter_prefix" {
  description = "워커 env 스크립트가 읽는 SSM 파라미터 프리픽스 (예: /wes/prod). 워커 롤은 이 아래 spring.datasource.url · photoselect.db.password · app.storage.bucket 세 개만 읽는다. AMI에 구워진 프리픽스와 다르면 user_data로 덮어야 한다"
  type        = string
}

variable "gpu_ami_id" {
  description = "워커 인스턴스에 쓸 AMI ID(modules/score-gpu 파이프라인 산출물). 바꾸면 인스턴스 replace"
  type        = string
}

variable "worker_instance_type" {
  description = "워커 인스턴스 타입. g6.xlarge(L4 24GB, 4 vCPU). G 쿼터: 빌드 4 + 운영 워커 2 × 4 = 12"
  type        = string
  default     = "g6.xlarge"
}

variable "gpu_root_throughput" {
  description = "워커 인스턴스 루트 gp3 처리량(MB/s). 기본 125, 미리보기 다운로드가 디스크에 막히면 250"
  type        = number
  default     = 125
}

variable "worker_subnet_ids" {
  description = "워커 인스턴스를 둘 퍼블릭 서브넷 — 키는 AZ 이름, 값은 서브넷 ID. 키마다 한 대씩 만든다(for_each 키가 인스턴스·알람 이름에 들어간다)"
  type        = map(string)
}

variable "worker_security_group_id" {
  description = "워커 인스턴스 SG(modules/security score_gpu — 인바운드 0, RDS SG가 참조)"
  type        = string
}

variable "photo_bucket_arn" {
  description = "사진 버킷 ARN — 워커는 previews/* 만 읽는다"
  type        = string
}

variable "score_repository_arn" {
  description = "워커가 부팅 때 pull 하는 score ECR 리포지토리 ARN"
  type        = string
}

variable "user_data" {
  description = "워커 인스턴스 user_data. 운영은 null(AMI의 image.env 그대로). dev는 운영 AMI를 쓰므로 부팅마다 image.env의 프리픽스·이미지를 덮는 cloud-config를 넘긴다"
  type        = string
  default     = null
}
