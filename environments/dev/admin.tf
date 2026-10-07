# dev 관리자 호스트(wes-dev-admin) — 백오피스와 관리자 API. 운영 루트 admin.tf와 같은 모양이고 대상만 dev다.
#
# tailnet 접근은 운영과 같은 태그(tag:wes-admin)를 쓴다 — tailnet policy의 443 grant를 그대로 받는다. 도메인은 dev.admin.easyselect.kr.
# DNS 레코드는 운영(WES-253)과 같은 2단계다: 첫 apply 뒤 Tailscale IP를 확인해 admin_tailscale_ipv4에 커밋하면 A 레코드가 생긴다.
# 런타임 설정은 /wes/admin-api/dev, Tailscale auth key는 /wes/dev-admin — 둘 다 앱 프리픽스(/wes/dev) 밖이다.

locals {
  admin_fqdn                         = "${var.admin_subdomain}.${var.zone_name}"
  admin_web_origin                   = "https://${local.admin_fqdn}"
  admin_instance_name                = "${local.name_prefix}-admin"
  admin_tailscale_auth_parameter_arn = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.admin_tailscale_auth_parameter_name}"
  admin_parameter_prefix_arn         = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.admin_parameter_prefix}"
}

module "admin_access" {
  source = "../../modules/admin-access"

  name_prefix   = local.admin_instance_name
  aws_region    = var.aws_region
  vpc_id        = data.aws_vpc.shared.id
  subnet_id     = local.public_subnet_ids[0]
  instance_type = var.admin_instance_type

  zone_id = data.aws_route53_zone.this.zone_id
  fqdn    = local.admin_fqdn

  tailscale_ipv4                = var.admin_tailscale_ipv4
  tailscale_hostname            = var.admin_tailscale_hostname
  tailscale_auth_parameter_name = var.admin_tailscale_auth_parameter_name
  tailscale_auth_parameter_arn  = local.admin_tailscale_auth_parameter_arn

  runtime_parameter_prefix_arn = local.admin_parameter_prefix_arn
  photo_bucket_arn             = module.storage.bucket_arn
  embedding_function_arn       = module.analysis.function_arns["embedder"]

  app_port         = var.admin_app_port
  proxy_https_port = var.admin_proxy_https_port
}

resource "aws_vpc_security_group_ingress_rule" "admin_to_rds" {
  security_group_id            = module.security.rds_security_group_id
  description                  = "PostgreSQL from dev admin API host"
  referenced_security_group_id = module.admin_access.security_group_id
  from_port                    = module.database.port
  to_port                      = module.database.port
  ip_protocol                  = "tcp"
}

# 운영 모니터링 SG에 덧붙이는 두 번째 규칙(첫째는 dev 앱의 loki_from_dev_app).
resource "aws_vpc_security_group_ingress_rule" "loki_from_dev_admin" {
  security_group_id            = data.aws_security_group.monitoring.id
  description                  = "Loki push from dev admin API host"
  referenced_security_group_id = module.admin_access.security_group_id
  from_port                    = 3100
  to_port                      = 3100
  ip_protocol                  = "tcp"
}

# --- /wes/admin-api/dev 런타임 파라미터 (운영 admin.tf의 admin_* 와 같은 키) ---
# spring.datasource.password만 수동 SecureString이다(state에 남기지 않는다).

resource "aws_ssm_parameter" "admin_datasource_url" {
  name  = "${var.admin_parameter_prefix}/spring.datasource.url"
  type  = "String"
  value = "jdbc:postgresql://${module.database.address}:${module.database.port}/${module.database.db_name}?sslmode=require"
}

resource "aws_ssm_parameter" "admin_datasource_username" {
  name  = "${var.admin_parameter_prefix}/spring.datasource.username"
  type  = "String"
  value = var.admin_db_username
}

resource "aws_ssm_parameter" "admin_photo_bucket" {
  name  = "${var.admin_parameter_prefix}/app.storage.bucket"
  type  = "String"
  value = module.storage.bucket_name
}

resource "aws_ssm_parameter" "admin_embedding_function" {
  name  = "${var.admin_parameter_prefix}/app.analysis.embedder-function-name"
  type  = "String"
  value = module.analysis.function_names["embedder"]
}

# Loki·Grafana는 운영 모니터링 서버를 같이 쓴다. 로그는 env 라벨로 갈린다.
resource "aws_ssm_parameter" "admin_logging_loki_url" {
  name  = "${var.admin_parameter_prefix}/app.logging.loki-url"
  type  = "String"
  value = data.aws_ssm_parameter.prod_loki_url.value
}

resource "aws_ssm_parameter" "admin_observability_grafana_url" {
  name  = "${var.admin_parameter_prefix}/app.admin.observability.grafana-base-url"
  type  = "String"
  value = "https://${var.monitoring_subdomain}.${var.zone_name}"
}

resource "aws_ssm_parameter" "admin_observability_loki_url" {
  name  = "${var.admin_parameter_prefix}/app.admin.observability.loki-base-url"
  type  = "String"
  value = "https://${var.monitoring_subdomain}.${var.zone_name}/api/datasources/proxy/uid/loki"
}

resource "aws_ssm_parameter" "admin_server_port" {
  name  = "${var.admin_parameter_prefix}/server.port"
  type  = "String"
  value = tostring(var.admin_api_port)
}

# 마이그레이션은 dev 공개 API(wes-dev-app)만 한다. 관리자 API는 검증만.
resource "aws_ssm_parameter" "admin_flyway_disabled" {
  name  = "${var.admin_parameter_prefix}/spring.flyway.enabled"
  type  = "String"
  value = "false"
}

resource "aws_ssm_parameter" "admin_hibernate_validate" {
  name  = "${var.admin_parameter_prefix}/spring.jpa.hibernate.ddl-auto"
  type  = "String"
  value = "validate"
}
