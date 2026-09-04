output "repository_urls" {
  description = "함수별 ECR 리포지토리 URL (키: embedder · score · categorize). AI 저장소 deploy.sh가 이름으로 조회하므로 보통 직접 쓸 일은 없다"
  value       = { for key, repo in aws_ecr_repository.this : key => repo.repository_url }
}

output "repository_arns" {
  description = "함수별 ECR 리포지토리 ARN — worker 배포 역할의 push 대상"
  value       = { for key, repo in aws_ecr_repository.this : key => repo.arn }
}

output "function_names" {
  description = "함수 이름 (키: embedder · score · categorize). 수동 실행·로그 조회 대상"
  value       = { for key, fn in aws_lambda_function.this : key => fn.function_name }
}

output "function_arns" {
  description = "함수 ARN — worker 배포 역할의 update-function-code 대상, 관리자 API의 재처리 호출 대상(embedder)"
  value       = { for key, fn in aws_lambda_function.this : key => fn.arn }
}

output "role_arns" {
  description = "함수별 실행 롤 ARN (SCP 차단 판별 등 IAM 정책 시뮬레이션용)"
  value       = { for key, role in aws_iam_role.this : key => role.arn }
}
