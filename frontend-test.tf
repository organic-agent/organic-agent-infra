locals {
  frontend_test_fqdn = "test.${var.zone_name}"
}

module "frontend_test" {
  source = "./modules/frontend-test"

  name_prefix = "${local.name_prefix}-frontend-test"
  aws_region  = var.aws_region
  vpc_id      = module.network.vpc_id
  subnet_id   = module.network.public_subnet_ids[0]
  zone_id     = data.aws_route53_zone.this.zone_id
  fqdn        = local.frontend_test_fqdn

  # 테스트 프론트는 가끔만 쓰여 비용을 줄이려 micro(1GiB)로 둔다(작성자 결정 2026-10-10). 배포 때 서버 안 Next 빌드가
  # 가장 메모리를 쓰는 순간이라 스왑 파일(user_data)에 기대고, 빌드가 느려질 수 있음을 감수한다.
  instance_type = "t4g.micro"
}

output "frontend_test_url" { value = module.frontend_test.url }
output "frontend_test_instance_id" { value = module.frontend_test.instance_id }
output "frontend_test_artifact_bucket" { value = module.frontend_test.artifact_bucket }

output "frontend_test_deploy_role_arn" { value = module.github_actions.frontend_test_deploy_role_arn }
output "frontend_test_deploy_document_name" { value = module.frontend_test.deploy_document_name }
