locals {
  name_prefix = "wes"

  # 파라미터 네이밍 컨벤션: /wes/<환경>/<스프링 프로퍼티>, 환경은 local/prod 두 개.
  # url/username은 Terraform이 자동 생성, password는 밖에서 수동 관리 (docs/runbook.md 참고).
  parameter_prefix_arn       = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.parameter_prefix}"
  db_password_parameter_name = "${var.parameter_prefix}/spring.datasource.password"
  db_password_parameter_arn  = "${local.parameter_prefix_arn}/spring.datasource.password"

  # S3 버킷의 CORS 허용 오리진. 앱이 읽는 cors.allowed-origins를 그대로 쓴다.
  #
  # 값을 변수로 또 두지 않는 이유: 브라우저는 API와 S3 양쪽에 요청을 보내고, 두 목록이
  # 어긋나면 로그인은 되는데 업로드만 프리플라이트에서 죽는다. 원인이 CORS라는 걸
  # 알아채기 어려운 종류의 고장이라, 애초에 갈릴 수 없게 한 곳에서 읽는다.
  web_origins = [for o in split(",", data.aws_ssm_parameter.cors_allowed_origins.value) : trimspace(o)]
}

data "aws_caller_identity" "current" {}

# 수동 등록 파라미터다(docs/deploy-order.md의 [2]). 없으면 여기서 apply가 멈추는데,
# 그편이 CORS가 반쯤 맞는 스택을 세우는 것보다 낫다.
data "aws_ssm_parameter" "cors_allowed_origins" {
  name = "${var.parameter_prefix}/cors.allowed-origins"
}

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

module "storage" {
  source = "./modules/storage"

  name_prefix      = local.name_prefix
  parameter_prefix = var.parameter_prefix
  app_role_name    = module.compute.instance_role_name
  web_origins      = local.web_origins
}

module "embedding" {
  source = "./modules/embedding"

  name_prefix      = local.name_prefix
  parameter_prefix = var.parameter_prefix

  # RDS와 같은 DB 서브넷에 들어간다. 이 출력이 S3 게이트웨이 엔드포인트를 기다리므로,
  # 함수가 만들어질 때는 이미 사진을 읽을 경로가 있다.
  subnet_ids        = module.network.db_subnet_ids
  security_group_id = module.security.embedder_security_group_id
  app_role_name     = module.compute.instance_role_name

  photo_bucket_name = module.storage.bucket_name
  photo_bucket_arn  = module.storage.bucket_arn

  # 비밀번호는 넘기지 않는다. 접속은 RDS IAM 인증이다 (modules/database의 주석 참고).
  db_host        = module.database.address
  db_port        = module.database.port
  db_name        = module.database.db_name
  db_resource_id = module.database.resource_id
  db_username    = var.embedder_db_username

  image_tag           = var.embedder_image_tag
  memory_mb           = var.embedder_memory_mb
  batch_size          = var.embedder_batch_size
  embedding_dimension = var.embedding_dimension
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
