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

output "ec2_instance_id" {
  description = "SSM 세션·포트포워딩의 --target 값 (임베더 로컬 실행 시 RDS 터널을 이 인스턴스로 뚫는다)"
  value       = module.compute.instance_id
}

output "ssh_command" {
  description = "비상용 직접 SSH (ssh_allowed_cidr 지정 후에만 동작). 평소엔 SSM 경유 — docs/runbook.md '서버 접속' 참조"
  value       = "ssh -i ~/.ssh/wes-aws-key ubuntu@${module.compute.public_ip}"
}

output "github_deploy_role_arn" {
  description = "서버 저장소의 AWS_DEPLOY_ROLE_ARN 시크릿에 넣을 값 (CD가 OIDC로 assume)"
  value       = module.github_actions.deploy_role_arn
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

output "photo_bucket" {
  description = "원본 사진 버킷 (이미 /wes/prod/app.storage.bucket에 기록됨)"
  value       = module.storage.bucket_name
}

output "embedder_repository_url" {
  description = "임베더 이미지를 푸시할 ECR 리포지토리 (docker push 대상)"
  value       = module.embedding.repository_url
}

output "embedder_function_name" {
  description = "임베딩 Lambda 이름. 수동 실행: aws lambda invoke --function-name <this> ..."
  value       = module.embedding.function_name
}

output "embedder_role_arn" {
  description = "임베딩 Lambda 실행 롤 ARN (SCP 차단 판별 — docs/runbook.md 'SCP 차단' 참조)"
  value       = module.embedding.role_arn
}

output "db_resource_id" {
  description = "RDS 리소스 ID(db-XXXX). rds-db:connect 정책 ARN이 인스턴스 이름이 아니라 이 값을 쓴다"
  value       = module.database.resource_id
}

output "monitoring_url" {
  description = "Grafana 주소 (admin / SSM /wes/monitoring/grafana.admin-password)"
  value       = "https://${module.monitoring.fqdn}"
}

output "monitoring_instance_id" {
  description = "모니터링 EC2 인스턴스 ID (SSM 세션 --target)"
  value       = module.monitoring.instance_id
}

output "monitoring_public_ip" {
  description = "모니터링 서버 EIP (고정)"
  value       = module.monitoring.public_ip
}

output "loki_push_url" {
  description = "앱이 로그를 보내는 Loki 주소 (이미 /wes/prod/app.logging.loki-url에 기록됨)"
  value       = module.monitoring.loki_push_url
}

output "github_tf_plan_role_arn" {
  description = "이 저장소의 AWS_PLAN_ROLE_ARN 시크릿에 넣을 값 (PR의 terraform plan이 assume)"
  value       = module.github_actions.tf_plan_role_arn
}

output "github_tf_apply_role_arn" {
  description = "이 저장소의 AWS_APPLY_ROLE_ARN 시크릿에 넣을 값 (main의 terraform apply가 assume)"
  value       = module.github_actions.tf_apply_role_arn
}
