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

output "github_admin_deploy_role_arn" {
  description = "백오피스 저장소의 AWS_DEPLOY_ROLE_ARN 시크릿에 넣을 값 (main CD만 OIDC로 assume)"
  value       = module.github_actions.admin_deploy_role_arn
}

output "github_admin_api_deploy_role_arn" {
  description = "서버 저장소의 AWS_ADMIN_API_DEPLOY_ROLE_ARN 시크릿에 넣을 값 (wes-admin 대상만 SSM 배포)"
  value       = module.github_actions.admin_api_deploy_role_arn
}

output "github_worker_deploy_role_arn" {
  description = "AI 저장소의 AWS_LAMBDA_DEPLOY_ROLE_ARN 변수(vars)에 넣을 값 (wes-embedder·wes-score·wes-categorize ECR/Lambda 전용)"
  value       = module.github_actions.worker_deploy_role_arn
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

output "dev_photo_bucket" {
  description = "로컬 개발용 사진 버킷 (이미 /wes/local/app.storage.bucket에 기록됨). 임베더·AI CLI의 S3_BUCKET"
  value       = module.storage_dev.bucket_name
}

output "lambda_repository_urls" {
  description = "Lambda 셋의 이미지를 푸시할 ECR 리포지토리 (키: embedder · score · categorize). AI 저장소 deploy.sh는 이름으로 찾는다"
  value       = module.analysis.repository_urls
}

output "lambda_function_names" {
  description = "AI Lambda 이름 (키: embedder · score · categorize). 수동 실행: aws lambda invoke --function-name <this> ..."
  value       = module.analysis.function_names
}

output "lambda_role_arns" {
  description = "Lambda 셋의 실행 롤 ARN (SCP 차단 판별 — docs/runbook.md 'SCP 차단' 참조)"
  value       = module.analysis.role_arns
}

output "vpc_interface_endpoint_ids" {
  description = "DB 서브넷의 인터페이스 엔드포인트 (lambda: 재호출·체인, bedrock-runtime: categorize naming). 시간당 과금 대상"
  value = {
    lambda          = module.network.lambda_endpoint_id
    bedrock_runtime = module.network.bedrock_runtime_endpoint_id
  }
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

output "admin_url" {
  description = "tailnet에 등록된 모든 기기에서 접근할 백오피스 URL"
  value       = "https://${module.admin_access.fqdn}"
}

output "admin_instance_id" {
  description = "백오피스 전용 서버의 SSM 대상 인스턴스 ID"
  value       = module.admin_access.instance_id
}

output "admin_public_ip" {
  description = "아웃바운드 전용 퍼블릭 IP. 보안 그룹 인바운드 규칙은 없다."
  value       = module.admin_access.public_ip
}

output "admin_dns_configured" {
  description = "admin.easyselect.kr A 레코드 생성 여부"
  value       = module.admin_access.dns_configured
}

output "admin_parameter_prefix" {
  description = "관리자 API가 Spring Cloud AWS로 읽을 전용 Parameter Store 경로"
  value       = var.admin_parameter_prefix
}

output "admin_db_password_ssm_parameter" {
  description = "관리자 API 전용 DB 비밀번호를 수동 SecureString으로 등록할 경로"
  value       = local.admin_db_password_parameter_name
}

output "admin_internal_network_name" {
  description = "BackOffice와 관리자 API 사이의 외부 라우팅 없는 Docker network"
  value       = module.admin_access.internal_network_name
}

output "admin_runtime_network_name" {
  description = "관리자 API만 AWS/RDS egress에 사용하는 Docker network"
  value       = module.admin_access.runtime_network_name
}

output "admin_deploy_lock_path" {
  description = "관리자 호스트의 API/BackOffice 배포를 직렬화할 flock 파일"
  value       = module.admin_access.deploy_lock_path
}
