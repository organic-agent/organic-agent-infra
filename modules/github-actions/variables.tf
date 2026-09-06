variable "name_prefix" {
  description = "리소스 이름 접두사. IAM 쓰기 권한의 울타리(`<prefix>-*`)로도 쓰인다"
  type        = string
}

variable "aws_region" {
  description = "AWS 리전 (SSM 문서 ARN·KMS ViaService 조건에 사용)"
  type        = string
}

variable "server_repository" {
  description = "공개/관리자 API CD가 도는 서버 저장소 (owner/repo) — 두 최소권한 배포 롤의 신뢰 조건"
  type        = string
}

variable "server_repository_id" {
  description = "서버 저장소의 immutable GitHub repository ID"
  type        = string
}

variable "repository_owner_id" {
  description = "네 저장소(서버·백오피스·AI·인프라)를 소유한 GitHub organization의 immutable owner ID"
  type        = string
}

variable "worker_oidc_subject" {
  description = "AI 저장소 main의 전체 immutable GitHub OIDC sub — worker 배포 롤의 정확한 단일 신뢰 조건"
  type        = string
}

variable "worker_repository_id" {
  description = "AI 저장소의 immutable GitHub repository ID"
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

variable "worker_repository_arns" {
  description = "worker 배포 역할이 이미지를 push할 ECR repository ARN 목록 (embedder · score · categorize)"
  type        = list(string)

  validation {
    condition     = length(var.worker_repository_arns) > 0 && alltrue([for a in var.worker_repository_arns : !strcontains(a, "*")])
    error_message = "worker_repository_arns는 와일드카드 없는 정확한 ECR repository ARN을 하나 이상 담아야 합니다."
  }
}

variable "worker_function_arns" {
  description = "worker 배포 역할이 코드 갱신·조회할 Lambda ARN 목록 (embedder · score · categorize)"
  type        = list(string)

  validation {
    condition     = length(var.worker_function_arns) > 0 && alltrue([for a in var.worker_function_arns : !strcontains(a, "*")])
    error_message = "worker_function_arns는 와일드카드 없는 정확한 Lambda 함수 ARN을 하나 이상 담아야 합니다."
  }
}

variable "frontend_test_oidc_subject" {
  description = "테스트 프론트 main의 정확한 immutable GitHub OIDC subject"
  type        = string
}

variable "frontend_test_repository_id" {
  description = "테스트 프론트의 immutable GitHub repository ID"
  type        = string
}

variable "frontend_test_instance_id" {
  description = "테스트 프론트 전용 배포 대상 EC2 ID"
  type        = string
}

variable "frontend_test_artifact_bucket_arn" {
  description = "테스트 프론트 소스 아카이브를 업로드할 전용 버킷 ARN"
  type        = string
}

variable "frontend_test_deploy_document_arn" {
  description = "임의 shell 명령 대신 허용하는 고정 테스트 프론트 배포 문서 ARN"
  type        = string
}
