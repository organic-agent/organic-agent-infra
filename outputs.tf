output "app_url" {
  description = "테스트 환경 기본 URL"
  value       = "https://${module.ingress.app_fqdn}"
}

output "oauth_redirect_uris" {
  description = "각 프로바이더 콘솔에 등록할 redirect URI (Spring Security 기본 패턴)"
  value = {
    kakao  = "https://${module.ingress.app_fqdn}/login/oauth2/code/kakao"
    google = "https://${module.ingress.app_fqdn}/login/oauth2/code/google"
    naver  = "https://${module.ingress.app_fqdn}/login/oauth2/code/naver"
  }
}

output "ec2_public_ip" {
  description = "앱 서버 퍼블릭 IP (stop/start 하면 바뀜)"
  value       = module.compute.public_ip
}

output "ssh_command" {
  description = "비상용 직접 SSH (ssh_allowed_cidr 지정 후에만 동작). 평소엔 SSM 경유 — docs/runbook.md '서버 접속' 참조"
  value       = "ssh -i ~/.ssh/wes-aws-key ubuntu@${module.compute.public_ip}"
}

output "github_deploy_role_arn" {
  description = "서버 저장소의 AWS_DEPLOY_ROLE_ARN 시크릿에 넣을 값 (CD가 OIDC로 assume)"
  value       = aws_iam_role.github_deploy.arn
}

output "rds_endpoint" {
  description = "RDS 엔드포인트 (host:port)"
  value       = module.database.endpoint
}

output "db_jdbc_url" {
  description = "application.yml에 넣을 JDBC URL"
  value       = "jdbc:postgresql://${module.database.address}:${module.database.port}/${module.database.db_name}"
}

output "db_password_ssm_parameter" {
  description = "읽는 법: aws ssm get-parameter --name <this> --with-decryption --query Parameter.Value --output text"
  value       = local.db_password_parameter_name
}
