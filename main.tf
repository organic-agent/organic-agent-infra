locals {
  name_prefix = "wes"

  # 파라미터 네이밍 컨벤션: /wes/<환경>/<스프링 프로퍼티>, 환경은 local/prod 두 개.
  # url/username은 Terraform이 자동 생성, password는 밖에서 수동 관리 (docs/runbook.md 참고).
  parameter_prefix_arn       = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.parameter_prefix}"
  db_password_parameter_name = "${var.parameter_prefix}/spring.datasource.password"
  db_password_parameter_arn  = "${local.parameter_prefix_arn}/spring.datasource.password"
}

data "aws_caller_identity" "current" {}

# 호스티드 존은 dns/ 스택 소유 (공유 리소스라 이 스택을 destroy 해도 남아있음).
data "aws_route53_zone" "this" {
  name = var.zone_name
}

module "network" {
  source = "./modules/network"

  name_prefix         = local.name_prefix
  vpc_cidr            = var.vpc_cidr
  azs                 = var.azs
  public_subnet_cidrs = var.public_subnet_cidrs
  db_subnet_cidrs     = var.db_subnet_cidrs
}

module "security" {
  source = "./modules/security"

  name_prefix      = local.name_prefix
  vpc_id           = module.network.vpc_id
  app_port         = var.app_port
  ssh_allowed_cidr = var.ssh_allowed_cidr
}

module "database" {
  source = "./modules/database"

  name_prefix                = local.name_prefix
  subnet_ids                 = module.network.db_subnet_ids
  security_group_id          = module.security.rds_security_group_id
  db_name                    = var.db_name
  db_username                = var.db_username
  parameter_prefix           = var.parameter_prefix
  password_ssm_parameter_arn = local.db_password_parameter_arn
  password_wo_version        = var.db_password_version
}

module "compute" {
  source = "./modules/compute"

  name_prefix              = local.name_prefix
  subnet_id                = module.network.public_subnet_ids[0]
  security_group_id        = module.security.ec2_security_group_id
  instance_type            = var.instance_type
  ssh_public_key           = var.ssh_public_key
  app_parameter_prefix_arn = local.parameter_prefix_arn
}

module "ingress" {
  source = "./modules/ingress"

  name_prefix       = local.name_prefix
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  security_group_id = module.security.alb_security_group_id
  zone_id           = data.aws_route53_zone.this.zone_id
  zone_name         = var.zone_name
  subdomain         = var.subdomain
  instance_id       = module.compute.instance_id
  app_port          = var.app_port
  health_check_path = var.health_check_path
}
