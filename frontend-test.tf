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
}

output "frontend_test_url" { value = module.frontend_test.url }
output "frontend_test_instance_id" { value = module.frontend_test.instance_id }
output "frontend_test_artifact_bucket" { value = module.frontend_test.artifact_bucket }

output "frontend_test_deploy_role_arn" { value = module.github_actions.frontend_test_deploy_role_arn }
output "frontend_test_deploy_document_name" { value = module.frontend_test.deploy_document_name }
