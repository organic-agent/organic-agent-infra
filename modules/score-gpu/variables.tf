variable "name_prefix" {
  description = "리소스 이름 접두사. 롤·프로파일 이름이 이 접두사로 시작해야 tf_apply의 IAM 울타리(`wes-*`)와 PassRole 범위 안에 든다"
  type        = string
}

variable "vpc_id" {
  description = "빌드 인스턴스용 보안 그룹을 만들 VPC"
  type        = string
}

variable "subnet_id" {
  description = "AMI 빌드 인스턴스를 띄울 퍼블릭 서브넷(공인 IP 자동 할당). SSM·ECR·NVIDIA 저장소에 IGW로 나간다"
  type        = string
}

variable "score_repository_url" {
  description = "score 워커 이미지의 ECR 리포지토리 URL (modules/analysis의 wes-score)"
  type        = string
}

variable "score_image_tag" {
  description = "워커가 부팅 때 pull 하는 이동 태그. AI 저장소 CI가 push마다 이 태그와 gpu-<sha>를 함께 올린다(계획 결정 B)"
  type        = string
  default     = "gpu"
}

variable "parameter_prefix" {
  description = "워커 env 스크립트가 읽는 SSM 파라미터 프리픽스 (예: /wes/prod). spring.datasource.url · photoselect.db.password · app.storage.bucket 세 개만 읽는다"
  type        = string
}

variable "build_instance_type" {
  description = "AMI 빌드·테스트 인스턴스 타입. 컴포넌트가 nvidia-smi로 드라이버를 검증하므로 GPU가 있어야 한다"
  type        = string
  default     = "g6.xlarge"
}

variable "nvidia_driver_branch" {
  description = "고정할 NVIDIA 드라이버 브랜치(AL2023 nvidia-release 저장소의 nvidia-driver-cuda-<branch>.*). 580은 LTS 브랜치. 바꾸면 component_version도 올린다"
  type        = string
  default     = "580"
}

variable "nvidia_driver_min_major" {
  description = "빌드가 통과하려면 드라이버 메이저 버전이 이 값 이상이어야 한다. 워커 이미지의 CUDA 12.x 런타임 하한(525)"
  type        = number
  default     = 525
}

variable "component_version" {
  description = "Image Builder 컴포넌트 버전(semver). 컴포넌트는 불변이라 YAML·files/·변수가 바뀌면 올려야 새 버전이 만들어진다"
  type        = string
  default     = "1.0.0"
}

variable "recipe_version" {
  description = "Image Builder 레시피 버전(semver). 레시피도 불변이라 컴포넌트 버전·블록 디바이스가 바뀌면 함께 올린다"
  type        = string
  default     = "1.0.0"
}

variable "worker_idle_stop_seconds" {
  description = "워커가 집을 사진이 없을 때 자기 인스턴스를 정지하기까지의 연속 유휴 초(WORKER_IDLE_STOP_SECONDS). 30 = 사용자 결정(2026-09-08, wes HANDOFF: 작업이 끝나면 30초 안에 꺼진다). AMI에 굽히므로 바꾸면 재빌드"
  type        = number
  default     = 30
}

variable "gpu_ami_id" {
  description = "워커 인스턴스에 쓸 AMI ID. 파이프라인이 만든 AMI를 사람이 확인해 박는다 — most_recent 데이터 소스는 빌드마다 replace를 만들어 쓰지 않는다. 인스턴스는 PR-3c에서 만든다(여기서는 선언만)"
  type        = string
  default     = null
}

variable "gpu_root_throughput" {
  description = "워커 인스턴스 루트 gp3 처리량(MB/s). 기본 125, 미리보기 다운로드가 디스크에 막히면 250. 인스턴스는 PR-3c에서 만든다(여기서는 선언만)"
  type        = number
  default     = 125
}
