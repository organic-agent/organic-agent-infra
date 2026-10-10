# dev 환경 — 운영과 같은 규격의 앱 계층(EC2·ALB·RDS·S3)과 AI 분석(Lambda 셋·GPU 워커 1대).
#
# 운영 스택(저장소 루트)과 state를 나눈다. dev의 apply·destroy가 운영 plan에 섞이지 않고, dev만 통째로 접을 수 있다.
# 네트워크는 운영 VPC를 그대로 쓴다 — 서브넷·S3 게이트웨이·Bedrock 리전 피어링(#71)을 다시 만들 이유가 없고, 경계는
# 보안 그룹이 긋는다(dev RDS는 dev SG만 받는다). 운영 쪽 리소스는 Name 태그로 찾아 읽기만 하고, 이 스택이 운영 리소스에
# 덧붙이는 것은 운영 모니터링 SG의 Loki 인그레스 규칙 하나뿐이다.
#
# 이름은 전부 `wes-dev-*`다 — 운영 tf_apply의 IAM 울타리(`wes-*`) 안이고, 운영 리소스(`wes-app`·`wes-score-gpu` 등)와
# 태그가 겹치지 않아 운영 CD·GpuController가 dev 인스턴스를 집지 않는다(반대도 마찬가지).
#
# 앱 쪽 환경 구분은 서버 저장소 몫이다: dev 프로필(spring.config.import = aws-parameterstore:/wes/dev/)과
# SPRING_PROFILES_ACTIVE=dev인 compose. 이 스택은 /wes/dev/ 프리픽스와 그걸 읽는 롤을 만든다.

locals {
  name_prefix = "wes-dev"
  # GPU 워커 Name 태그. 앱 롤의 Start/Stop 조건(compute)·워커 태그(score_gpu)·wes가 읽는 app.analysis.gpu.tag가 같은 값을 쓴다.
  score_gpu_tag_name = "${local.name_prefix}-score-gpu"

  parameter_prefix_arn      = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.parameter_prefix}"
  db_password_parameter_arn = "${local.parameter_prefix_arn}/spring.datasource.password"
  public_subnet_ids         = [for az in var.azs : data.aws_subnet.public[az].id]
  db_subnet_ids             = [for az in var.azs : data.aws_subnet.db[az].id]
  public_web_origins        = [for o in split(",", data.aws_ssm_parameter.cors_allowed_origins.value) : trimspace(o) if trimspace(o) != ""]
  gpu_worker_subnet_ids     = { for az in var.gpu_worker_azs : az => data.aws_subnet.public[az].id }
  score_gpu_image           = "${module.analysis.repository_urls["score"]}:${var.score_gpu_image_tag}"
}

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "this" {
  name = var.zone_name
}

# --- 운영 스택에서 읽어 오는 것 ---

data "aws_vpc" "shared" {
  tags = {
    Name = "${var.shared_name_prefix}-vpc"
  }
}

data "aws_subnet" "public" {
  for_each = toset(var.azs)

  vpc_id = data.aws_vpc.shared.id
  tags = {
    Name = "${var.shared_name_prefix}-public-${each.key}"
  }
}

data "aws_subnet" "db" {
  for_each = toset(var.azs)

  vpc_id = data.aws_vpc.shared.id
  tags = {
    Name = "${var.shared_name_prefix}-db-${each.key}"
  }
}

# dev 앱 로그도 운영 모니터링 서버의 Loki로 보낸다(서버 저장소 alloy 설정이 env 라벨로 가른다). 모니터링 서버를 하나 더
# 두지 않는 대신 Loki 수신 포트를 dev 앱 SG에도 연다.
data "aws_security_group" "monitoring" {
  vpc_id = data.aws_vpc.shared.id
  tags = {
    Name = "${var.shared_name_prefix}-monitoring"
  }
}

# 운영 스택이 모니터링 서버 프라이빗 IP로 만드는 값. 모니터링 서버가 교체되면 운영 apply가 이 값을 바꾸고, dev는 다음
# dev apply에서 따라간다(그 사이 dev 로그만 alloy가 쌓아 두었다가 이어 보낸다).
data "aws_ssm_parameter" "prod_loki_url" {
  name = "${var.prod_parameter_prefix}/app.logging.loki-url"
}

# 수동 등록 파라미터(docs/runbooks/dev-environment.md). 앱의 dev 프로필 CORS와 dev 버킷 CORS가 같은 값을 읽는다 — 운영과 같은 이유.
data "aws_ssm_parameter" "cors_allowed_origins" {
  name = "${var.parameter_prefix}/cors.allowed-origins"
}

# --- 앱 계층 ---

# 운영과 같은 모듈이라 모니터링용 SG(wes-dev-monitoring)도 하나 생기지만 어디에도 붙지 않는다(ENI 없음 → 비용·노출 없음).
module "security" {
  source = "../../modules/security"

  name_prefix      = local.name_prefix
  vpc_id           = data.aws_vpc.shared.id
  app_port         = var.app_port
  ssh_allowed_cidr = var.ssh_allowed_cidr
}

resource "aws_vpc_security_group_ingress_rule" "loki_from_dev_app" {
  security_group_id            = data.aws_security_group.monitoring.id
  description                  = "Loki push from dev app server"
  referenced_security_group_id = module.security.ec2_security_group_id
  from_port                    = 3100
  to_port                      = 3100
  ip_protocol                  = "tcp"
}

resource "aws_ssm_parameter" "loki_url" {
  name  = "${var.parameter_prefix}/app.logging.loki-url"
  type  = "String"
  value = data.aws_ssm_parameter.prod_loki_url.value
}

# 버킷 이름은 `wes-dev-photos-<계정>`. 로컬 개발용 버킷은 운영 스택의 `wes-local-photos-<계정>`(storage_local, /wes/local)으로
# 따로다 — 로컬 pg와 dev RDS의 갤러리 id가 겹치면 `galleries/{id}/` 키 공간이 섞인다.
# 이 이름은 예전 로컬 버킷 이름이라, 옛 버킷을 비우고 지운 뒤에야 만들 수 있다(docs/runbooks/dev-environment.md).
module "storage" {
  source = "../../modules/storage"

  name_prefix      = local.name_prefix
  parameter_prefix = var.parameter_prefix
  app_role_name    = module.compute.instance_role_name
  # 백오피스도 브라우저에서 버킷에 직접 올린다(운영 루트의 web_origins와 같은 이유).
  web_origins = distinct(concat(local.public_web_origins, [local.admin_web_origin]))
}

module "database" {
  source = "../../modules/database"

  name_prefix                = local.name_prefix
  subnet_ids                 = local.db_subnet_ids
  security_group_id          = module.security.rds_security_group_id
  db_name                    = var.db_name
  db_username                = var.db_username
  parameter_prefix           = var.parameter_prefix
  password_ssm_parameter_arn = local.db_password_parameter_arn
  password_wo_version        = var.db_password_version
}

module "compute" {
  source = "../../modules/compute"

  name_prefix              = local.name_prefix
  subnet_id                = local.public_subnet_ids[0]
  security_group_id        = module.security.ec2_security_group_id
  instance_type            = var.instance_type
  ssh_public_key           = var.ssh_public_key
  app_parameter_prefix_arn = local.parameter_prefix_arn
  bedrock_model_id         = var.bedrock_model_id
  bedrock_region           = var.bedrock_region
  score_gpu_tag_name       = local.score_gpu_tag_name
}

module "ingress" {
  source = "../../modules/ingress"

  name_prefix       = local.name_prefix
  vpc_id            = data.aws_vpc.shared.id
  public_subnet_ids = local.public_subnet_ids
  security_group_id = module.security.alb_security_group_id
  zone_id           = data.aws_route53_zone.this.zone_id
  zone_name         = var.zone_name
  subdomain         = var.subdomain
  instance_id       = module.compute.instance_id
  app_port          = var.app_port
  health_check_path = var.health_check_path
}

# 운영 루트와 같은 이유로 Terraform이 소유한다 — 앱 기본값은 서울 + `global.`이라 덮지 않으면 IAM과 어긋난다(#71).
resource "aws_ssm_parameter" "llm_region" {
  name  = "${var.parameter_prefix}/app.llm.region"
  type  = "String"
  value = var.bedrock_region
}

resource "aws_ssm_parameter" "llm_model_id" {
  name  = "${var.parameter_prefix}/app.llm.model-id"
  type  = "String"
  value = var.bedrock_model_id
}

# --- AI 분석 ---

# ECR도 dev 전용(wes-dev-embedder·score·categorize)이다. 운영 리포지토리를 같이 쓰면 dev CD가 운영 이동 태그(`latest`·`gpu`)를
# 덮을 수 있는데 ECR IAM은 태그 단위로 막지 못한다 — 특히 운영 GPU 워커는 부팅마다 `gpu`를 pull 한다.
# 첫 apply 전에 세 리포지토리에 이미지가 있어야 한다(런북의 부트스트랩 순서).
module "analysis" {
  source = "../../modules/analysis"

  name_prefix      = local.name_prefix
  parameter_prefix = var.parameter_prefix

  # 운영 DB 서브넷 — S3 게이트웨이와 Bedrock 리전 피어링 라우트가 이미 걸려 있다. 보안 그룹은 dev 것이라 dev RDS에만 닿는다.
  subnet_ids        = local.db_subnet_ids
  security_group_id = module.security.embedder_security_group_id
  app_role_name     = module.compute.instance_role_name

  photo_bucket_name = module.storage.bucket_name
  photo_bucket_arn  = module.storage.bucket_arn

  db_host              = module.database.address
  db_port              = module.database.port
  db_name              = module.database.db_name
  db_resource_id       = module.database.resource_id
  embedder_db_username = var.embedder_db_username
  analysis_db_username = var.analysis_db_username

  image_tag = var.lambda_image_tag

  embedder_memory_mb                      = var.embedder_memory_mb
  embedder_batch_size                     = var.embedder_batch_size
  embedder_reserved_concurrent_executions = var.embedder_reserved_concurrent_executions
  embedding_dimension                     = var.embedding_dimension

  score_memory_mb                           = var.score_memory_mb
  score_ephemeral_storage_mb                = var.score_ephemeral_storage_mb
  score_reserved_concurrent_executions      = var.score_reserved_concurrent_executions
  categorize_memory_mb                      = var.categorize_memory_mb
  categorize_reserved_concurrent_executions = var.categorize_reserved_concurrent_executions
  bedrock_model_id                          = var.bedrock_model_id
  bedrock_region                            = var.bedrock_region

  gpu_score_enabled = var.gpu_score_enabled && length(var.gpu_worker_azs) > 0
}

# wes GpuController가 워커를 찾는 태그. 앱 기본값(application-variable.yml)은 운영 태그 wes-score-gpu라, 덮지 않으면 dev 앱
# 롤의 Start 권한(태그 조건 wes-dev-score-gpu)에 막혀 GPU를 못 켜고 Lambda로만 폴백한다.
resource "aws_ssm_parameter" "gpu_tag" {
  name  = "${var.parameter_prefix}/app.analysis.gpu.tag"
  type  = "String"
  value = local.score_gpu_tag_name
}

# dev GPU 워커 — AMI는 굽지 않고 운영 파이프라인 산출물을 쓴다. 그 AMI의 /etc/wes-score/image.env에는 운영 프리픽스와
# 운영 이미지(wes-score:gpu)가 구워져 있어, 부팅마다 bootcmd로 dev 값으로 덮는다. bootcmd는 cloud-init 네트워크 단계
# (network-online.target 전)에 매 부팅 돌고, wes-score.service는 network-online.target 뒤에 뜬다. 혹시 순서가 어긋나도
# 워커 롤이 /wes/prod를 읽지 못해 env 스크립트가 실패하고 15초 뒤 재시작(Restart=on-failure)에서 고쳐진 파일을 읽는다.
module "score_gpu" {
  source = "../../modules/score-gpu-workers"

  name                     = local.score_gpu_tag_name
  parameter_prefix         = var.parameter_prefix
  gpu_ami_id               = var.gpu_ami_id
  worker_instance_type     = var.gpu_instance_type
  worker_subnet_ids        = local.gpu_worker_subnet_ids
  worker_security_group_id = module.security.score_gpu_security_group_id
  photo_bucket_arn         = module.storage.bucket_arn
  score_repository_arn     = module.analysis.repository_arns["score"]

  user_data = <<-EOT
    #cloud-config
    bootcmd:
      - sed -i -e 's|^PARAMETER_PREFIX=.*|PARAMETER_PREFIX=${var.parameter_prefix}|' -e 's|^WES_SCORE_IMAGE=.*|WES_SCORE_IMAGE=${local.score_gpu_image}|' /etc/wes-score/image.env
  EOT
}
