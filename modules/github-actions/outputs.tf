output "deploy_role_arn" {
  description = "서버 저장소의 AWS_DEPLOY_ROLE_ARN 시크릿 값"
  value       = aws_iam_role.deploy.arn
}

output "admin_deploy_role_arn" {
  description = "백오피스 저장소의 AWS_DEPLOY_ROLE_ARN 시크릿 값"
  value       = aws_iam_role.admin_deploy.arn
}

output "admin_api_deploy_role_arn" {
  description = "서버 저장소가 관리자 API를 wes-admin에 배포할 때 쓰는 AWS_ADMIN_API_DEPLOY_ROLE_ARN 값"
  value       = aws_iam_role.admin_api_deploy.arn
}

output "worker_deploy_role_arn" {
  description = "AI 저장소가 Lambda 셋의 ECR/Lambda를 배포할 때 쓰는 AWS_LAMBDA_DEPLOY_ROLE_ARN 변수 값"
  value       = aws_iam_role.worker_deploy.arn
}

output "tf_plan_role_arn" {
  description = "이 저장소의 AWS_PLAN_ROLE_ARN 시크릿 값"
  value       = aws_iam_role.tf_plan.arn
}

output "tf_apply_role_arn" {
  description = "이 저장소의 AWS_APPLY_ROLE_ARN 시크릿 값"
  value       = aws_iam_role.tf_apply.arn
}

output "frontend_test_deploy_role_arn" {
  description = "테스트 프론트 GitHub Actions의 AWS_DEPLOY_ROLE_ARN 변수"
  value       = aws_iam_role.frontend_test_deploy.arn
}
