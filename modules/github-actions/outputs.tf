output "deploy_role_arn" {
  description = "서버 저장소의 AWS_DEPLOY_ROLE_ARN 시크릿 값"
  value       = aws_iam_role.deploy.arn
}

output "tf_plan_role_arn" {
  description = "이 저장소의 AWS_PLAN_ROLE_ARN 시크릿 값"
  value       = aws_iam_role.tf_plan.arn
}

output "tf_apply_role_arn" {
  description = "이 저장소의 AWS_APPLY_ROLE_ARN 시크릿 값"
  value       = aws_iam_role.tf_apply.arn
}
