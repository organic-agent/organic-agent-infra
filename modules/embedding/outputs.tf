output "repository_url" {
  description = "임베더 이미지를 푸시할 ECR 리포지토리 URL"
  value       = aws_ecr_repository.this.repository_url
}

output "function_name" {
  description = "임베딩 Lambda 이름 (수동 실행과 로그 조회 대상)"
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "임베딩 Lambda ARN"
  value       = aws_lambda_function.this.arn
}
