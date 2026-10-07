variable "aws_region" {
  description = "AWS 리전. 운영 스택과 같은 VPC를 쓰므로 운영과 같아야 한다"
  type        = string
  default     = "ap-northeast-2"
}

variable "zone_name" {
  description = "Route53 호스티드 존 도메인 (dns/ 스택 소유)"
  type        = string
  default     = "easyselect.kr"
}

variable "subdomain" {
  description = "dev API 서브도메인(존 이름 앞부분). dev.api.easyselect.kr도 easyselect.kr 존 안의 레코드라 존을 나누지 않는다"
  type        = string
  default     = "dev.api"
}

variable "parameter_prefix" {
  description = "dev 앱이 읽는 SSM 프리픽스. 서버의 dev 프로필이 aws-parameterstore:/wes/dev/ 를 import 한다"
  type        = string
  default     = "/wes/dev"

  validation {
    condition     = var.parameter_prefix != "/wes/prod" && !startswith(var.parameter_prefix, "/wes/prod/")
    error_message = "dev 스택은 운영 프리픽스(/wes/prod)를 쓸 수 없습니다."
  }
}

variable "prod_parameter_prefix" {
  description = "운영 앱 프리픽스. dev는 여기서 Loki push URL(운영 스택이 쓰는 값) 하나만 읽는다"
  type        = string
  default     = "/wes/prod"
}

# --- 공유하는 운영 네트워크 ---

variable "shared_name_prefix" {
  description = "운영 스택의 이름 접두사. VPC·서브넷·모니터링 SG를 이 접두사의 Name 태그로 찾는다"
  type        = string
  default     = "wes"
}

variable "azs" {
  description = "운영 VPC의 가용 영역 (운영 스택 azs와 같아야 서브넷을 찾는다)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

# --- 앱 계층 (운영과 같은 규격) ---

variable "instance_type" {
  description = "앱 EC2 타입 (arm64). 운영과 같은 규격"
  type        = string
  default     = "t4g.micro"
}

variable "app_port" {
  description = "Spring Boot 앱이 리슨하는 포트"
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "ALB 헬스체크 경로"
  type        = string
  default     = "/actuator/health"
}

variable "ssh_allowed_cidr" {
  description = "앱 EC2에 SSH를 허용할 CIDR. null이면 22번 규칙 없음 — 평소엔 SSM Session Manager"
  type        = string
  default     = null
}

# 운영 스택과 같은 키. 퍼블릭 키는 비밀이 아니다.
variable "ssh_public_key" {
  description = "EC2 키 페어(wes-dev-key)로 등록할 SSH 퍼블릭 키 — 운영 wes-aws-key와 같은 키"
  type        = string
  default     = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCtn/PIssH3P2nIznmwHpNJqdLqD8SmQt3NT1qy7+0KgjGM8MDXnv7z+S3UawTCOyow1OdGEkQ3Oe+6P1Ge9S0qcvZjmTVJHpWov/tNmwR42Z4wgc/b5s753zpvtEmvfFtMC6LANoEOHk0mbUQ4dqANQ4ny0kOESAQYK19vr+UCjEIPAaTQLoWr33xayULlV3IJz29jjAnjbG9PTfcD9c3Zm/ihtO42Z7wAeYQrgMzAjnmn7m0MwN/aKS9Q4OQm25rRRhl27kQC9AyxqQM/JpMJxUeUJla/mawhRsLI8+Fxpr/Bj9J2KIpYEMU1ylfcM8QzW8tqEsGqIsZJieAuSHCF wes-aws-key"
}

variable "db_name" {
  description = "초기 PostgreSQL 데이터베이스 이름 (운영과 같은 이름, 인스턴스가 다르다)"
  type        = string
  default     = "wes_db"
}

variable "db_username" {
  description = "PostgreSQL 마스터 계정명"
  type        = string
  default     = "wes_admin"
}

variable "db_password_version" {
  description = "SSM /wes/dev/spring.datasource.password 변경 후 RDS에 반영하려면 이 값을 올릴 것"
  type        = number
  default     = 1
}

# --- AI 분석 (Lambda 셋 + GPU 워커) ---

variable "embedder_db_username" {
  description = "임베더 Lambda의 DB 사용자. dev RDS 안에 수동 생성한다(docs/runbooks/dev-environment.md)"
  type        = string
  default     = "embedder"
}

variable "analysis_db_username" {
  description = "score·categorize Lambda와 GPU 워커의 DB 사용자. dev RDS 안에 수동 생성한다"
  type        = string
  default     = "photoselect"
}

variable "lambda_image_tag" {
  description = "dev ECR(wes-dev-*)에서 Lambda가 쓰는 이미지 태그. 첫 apply 전에 세 리포지토리에 있어야 한다(런북의 이미지 복사 단계)"
  type        = string
  default     = "latest"
}

variable "embedder_memory_mb" {
  description = "임베딩 Lambda 메모리 — 운영과 같은 값"
  type        = number
  default     = 3008
}

variable "embedder_batch_size" {
  description = "임베더가 모델에 한 번에 넣는 사진 수 — 운영과 같은 값"
  type        = number
  default     = 8
}

variable "embedding_dimension" {
  description = "임베딩 폭. 앱의 vector(n) 컬럼과 같아야 한다 — 운영과 같은 값"
  type        = number
  default     = 768
}

variable "score_memory_mb" {
  description = "score Lambda 메모리 — 운영과 같은 값"
  type        = number
  default     = 8192
}

variable "score_ephemeral_storage_mb" {
  description = "score Lambda의 /tmp — 운영과 같은 값"
  type        = number
  default     = 10240
}

variable "score_reserved_concurrent_executions" {
  description = "score 동시 실행 상한 — 운영과 같은 값. 계정 동시성 400 중 운영 66 + dev 66을 예약해도 비예약 268(하한 100)이 남는다"
  type        = number
  default     = 32
}

variable "categorize_memory_mb" {
  description = "categorize Lambda 메모리 — 운영과 같은 값"
  type        = number
  default     = 3008
}

variable "categorize_reserved_concurrent_executions" {
  description = "categorize 동시 실행 상한 — 운영과 같은 값"
  type        = number
  default     = 2
}

variable "bedrock_model_id" {
  description = "categorize와 앱이 부르는 Bedrock 프로필 ID. 운영 스택 bedrock_model_id와 같은 값(#71 — 조직 SCP로 `us.`)"
  type        = string
  default     = "us.anthropic.claude-sonnet-4-6"
}

variable "bedrock_region" {
  description = "Bedrock을 부르는 리전. 운영 스택이 이 리전에 둔 엔드포인트 VPC·피어링을 같은 VPC에 있는 dev도 그대로 탄다"
  type        = string
  default     = "us-east-1"
}

variable "gpu_score_enabled" {
  description = "SSM /wes/dev/app.analysis.gpu.enabled. true면 dev 앱이 점수를 dev GPU 워커에 맡기고 score Lambda는 폴백"
  type        = bool
  default     = true
}

variable "gpu_ami_id" {
  description = "dev GPU 워커 AMI. dev는 AMI를 굽지 않고 운영 파이프라인 산출물을 쓴다 — 운영 스택 gpu_ami_id를 올릴 때 같이 올린다"
  type        = string
  default     = "ami-0f3e867e2ed3964ce"
}

variable "gpu_instance_type" {
  description = "dev GPU 워커 타입. G 쿼터 12 vCPU = 운영 워커 2 × 4 + AMI 빌드 4 — dev 워커(4)는 빌드 몫을 빌려 쓴다. 빌드·운영 2대·dev가 한꺼번에 켜지면 늦게 켜는 쪽이 쿼터에 막힌다"
  type        = string
  default     = "g6.xlarge"
}

variable "gpu_worker_azs" {
  description = "dev GPU 워커를 둘 AZ. 한 AZ에 한 대. 빈 목록이면 워커를 만들지 않는다(그때 gpu_score_enabled도 false로)"
  type        = list(string)
  default     = ["ap-northeast-2a"]
}

variable "score_gpu_image_tag" {
  description = "dev GPU 워커가 부팅 때 pull 하는 wes-dev-score 태그. AI 저장소의 dev CD가 이 태그를 민다. `gpu-`로 시작하면 ECR 라이프사이클(최근 3개)에 걸리므로 그 접두사는 쓰지 않는다"
  type        = string
  default     = "gpu"

  validation {
    condition     = !startswith(var.score_gpu_image_tag, "gpu-")
    error_message = "score_gpu_image_tag는 gpu- 로 시작할 수 없습니다 — 불변 태그용 라이프사이클 규칙이 지웁니다."
  }
}

# --- CD (GitHub OIDC) ---

variable "dev_branch" {
  description = "dev 배포를 트리거하는 브랜치. 서버·AI 저장소 모두 이 브랜치의 워크플로만 dev 배포 롤을 assume 한다"
  type        = string
  default     = "develop"
}

variable "github_repository_owner_id" {
  description = "organic-agent GitHub organization의 immutable owner ID"
  type        = string
  default     = "299031009"
}

variable "server_repository" {
  description = "서버 저장소 owner/name. 2026-07-15 이전 생성이라 OIDC sub가 이름 기반이다(운영 deploy 롤과 같은 규칙)"
  type        = string
  default     = "organic-agent/organic-agent-server"
}

variable "server_repository_id" {
  description = "organic-agent-server의 immutable repository ID"
  type        = string
  default     = "1297201474"
}

variable "ai_oidc_subject_prefix" {
  description = "AI 저장소 OIDC sub의 immutable 접두사(`:ref:...` 앞까지). 운영 ai_github_oidc_subject와 같은 형식"
  type        = string
  default     = "repo:organic-agent@299031009/organic-agent-ai@1336874708"
}

variable "ai_repository_id" {
  description = "organic-agent-ai의 immutable repository ID"
  type        = string
  default     = "1336874708"
}
