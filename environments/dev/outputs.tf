output "app_url" {
  description = "dev API 기본 URL"
  value       = "https://${module.ingress.app_fqdn}"
}

output "oauth_redirect_uris" {
  description = "각 프로바이더 콘솔에 추가 등록할 dev redirect URI (Spring Security 기본 패턴)"
  value = {
    kakao  = "https://${module.ingress.app_fqdn}/login/oauth2/code/kakao"
    google = "https://${module.ingress.app_fqdn}/login/oauth2/code/google"
    naver  = "https://${module.ingress.app_fqdn}/login/oauth2/code/naver"
  }
}

output "parameter_prefix" {
  description = "dev 앱이 읽는 SSM 프리픽스 — 서버 dev 프로필의 aws-parameterstore 경로"
  value       = var.parameter_prefix
}

output "ec2_instance_id" {
  description = "dev 앱 서버 인스턴스 ID (SSM 세션·RDS 포트포워딩의 --target)"
  value       = module.compute.instance_id
}

output "ec2_instance_name" {
  description = "dev 앱 서버 Name 태그 — 서버 dev CD의 INSTANCE_NAME_TAG"
  value       = "${local.name_prefix}-app"
}

output "rds_endpoint" {
  description = "dev RDS 엔드포인트 (host:port)"
  value       = module.database.endpoint
}

output "db_password_ssm_parameter" {
  description = "dev RDS 마스터 비밀번호 파라미터(수동 등록)"
  value       = "${var.parameter_prefix}/spring.datasource.password"
}

output "photo_bucket" {
  description = "dev 사진 버킷"
  value       = module.storage.bucket_name
}

output "lambda_repository_urls" {
  description = "dev ECR 리포지토리 URL (AI 저장소 dev CD가 push)"
  value       = module.analysis.repository_urls
}

output "lambda_function_names" {
  description = "dev Lambda 함수 이름"
  value       = module.analysis.function_names
}

output "score_gpu_image" {
  description = "dev GPU 워커가 부팅 때 pull 하는 이미지"
  value       = local.score_gpu_image
}

output "score_gpu_worker_instance_ids" {
  description = "dev GPU 워커 인스턴스 ID (키: AZ). wes는 태그 Name=wes-dev-score-gpu로 찾는다"
  value       = module.score_gpu.worker_instance_ids
}

output "github_deploy_role_arn" {
  description = "서버 저장소 dev CD 롤 ARN — 서버 저장소 시크릿 AWS_DEV_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.deploy.arn
}

output "github_worker_deploy_role_arn" {
  description = "AI 저장소 dev CD 롤 ARN — AI 저장소 시크릿 AWS_DEV_WORKER_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.worker_deploy.arn
}

output "admin_url" {
  description = "dev 관리자(백오피스) 주소 — tailnet에서만. admin_tailscale_ipv4를 커밋하기 전엔 DNS 레코드가 없다"
  value       = local.admin_web_origin
}

output "admin_instance_id" {
  description = "dev 관리자 인스턴스 ID. 첫 apply 뒤 SSM으로 `tailscale ip -4`를 확인한다"
  value       = module.admin_access.instance_id
}

output "admin_dns_configured" {
  description = "dev 관리자 A 레코드가 만들어졌는지"
  value       = module.admin_access.dns_configured
}

output "github_admin_api_deploy_role_arn" {
  description = "서버 저장소 dev CD의 AWS_DEV_ADMIN_API_DEPLOY_ROLE_ARN 값"
  value       = aws_iam_role.admin_api_deploy.arn
}

output "github_admin_deploy_role_arn" {
  description = "백오피스 저장소 dev CD의 AWS_DEV_DEPLOY_ROLE_ARN 값"
  value       = aws_iam_role.admin_deploy.arn
}
