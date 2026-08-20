variable "name_prefix" {
  description = "리소스 이름 접두사. IAM 쓰기 권한의 울타리(`<prefix>-*`)로도 쓰인다"
  type        = string
}

variable "aws_region" {
  description = "AWS 리전 (SSM 문서 ARN·KMS ViaService 조건에 사용)"
  type        = string
}

variable "server_repository" {
  description = "앱 CD가 도는 서버 저장소 (owner/repo) — 배포 롤의 신뢰 조건"
  type        = string
}

variable "infra_repository" {
  description = "이 인프라 저장소 (owner/repo) — plan/apply 롤의 신뢰 조건"
  type        = string
}

variable "app_instance_name" {
  description = "앱 EC2의 Name 태그. 배포 롤은 이 태그의 인스턴스에만 SSM 명령을 보낼 수 있다"
  type        = string
}
