variable "name_prefix" {
  description = "리소스 이름 접두사. IAM 쓰기 권한의 울타리(`<prefix>-*`)로도 쓰인다"
  type        = string
}

variable "aws_region" {
  description = "AWS 리전 (SSM 문서 ARN·KMS ViaService 조건에 사용)"
  type        = string
}

variable "server_repository" {
  description = "공개/관리자 API/worker CD가 도는 서버 저장소 (owner/repo) — 세 최소권한 배포 롤의 신뢰 조건"
  type        = string
}

variable "server_repository_id" {
  description = "서버 저장소의 immutable GitHub repository ID"
  type        = string
}

variable "repository_owner_id" {
  description = "세 저장소를 소유한 GitHub organization의 immutable owner ID"
  type        = string
}

variable "admin_oidc_subject" {
  description = "백오피스 main의 전체 immutable GitHub OIDC sub — 전용 배포 롤의 정확한 단일 신뢰 조건"
  type        = string
}

variable "admin_repository_id" {
  description = "백오피스 저장소의 immutable GitHub repository ID"
  type        = string
}

variable "infra_repository" {
  description = "이 인프라 저장소 (owner/repo) — plan/apply 롤의 신뢰 조건"
  type        = string
}

variable "infra_repository_id" {
  description = "인프라 저장소의 immutable GitHub repository ID"
  type        = string
}

variable "app_instance_name" {
  description = "앱 EC2의 Name 태그. 배포 롤은 이 태그의 인스턴스에만 SSM 명령을 보낼 수 있다"
  type        = string
}

variable "admin_instance_name" {
  description = "백오피스 EC2의 Name 태그. 전용 배포 롤은 이 태그의 인스턴스에만 SSM 명령을 보낼 수 있다"
  type        = string
}

variable "worker_repository_arn" {
  description = "worker 배포 역할이 이미지를 push할 단일 embedder ECR repository ARN"
  type        = string
}

variable "worker_function_arn" {
  description = "worker 배포 역할이 코드 갱신·조회할 단일 embedder Lambda ARN"
  type        = string
}
