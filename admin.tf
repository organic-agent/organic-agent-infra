locals {
  admin_fqdn                         = "${var.admin_subdomain}.${var.zone_name}"
  admin_tailscale_auth_parameter_arn = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.admin_tailscale_auth_parameter_name}"
  admin_parameter_prefix_arn         = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.admin_parameter_prefix}"
  admin_db_password_parameter_name   = "${var.admin_parameter_prefix}/spring.datasource.password"
}

module "admin_access" {
  source = "./modules/admin-access"

  name_prefix   = "${local.name_prefix}-admin"
  aws_region    = var.aws_region
  vpc_id        = module.network.vpc_id
  subnet_id     = module.network.public_subnet_ids[0]
  instance_type = var.admin_instance_type

  zone_id = data.aws_route53_zone.this.zone_id
  fqdn    = local.admin_fqdn

  tailscale_ipv4                = var.admin_tailscale_ipv4
  tailscale_hostname            = var.admin_tailscale_hostname
  tailscale_auth_parameter_name = var.admin_tailscale_auth_parameter_name
  tailscale_auth_parameter_arn  = local.admin_tailscale_auth_parameter_arn
  tailscale_auth_kms_key_arn    = var.admin_tailscale_auth_kms_key_arn

  runtime_parameter_prefix_arn = local.admin_parameter_prefix_arn
  runtime_kms_key_arn          = var.admin_runtime_kms_key_arn
  photo_bucket_arn             = module.storage.bucket_arn
  embedding_function_arn       = module.embedding.function_arn

  app_port         = var.admin_app_port
  proxy_https_port = var.admin_proxy_https_port
}

# 이 두 SG 참조 규칙을 security 모듈 안에 넣으면 admin_access → embedding → security →
# admin_access 순환 의존이 생긴다. 교차 모듈 연결만 루트에 두어 각 보안 그룹 자체의 생성과
# 관리자 런타임의 RDS/Loki 최소 경계를 동시에 유지한다.
resource "aws_vpc_security_group_ingress_rule" "admin_to_rds" {
  security_group_id            = module.security.rds_security_group_id
  description                  = "PostgreSQL from private admin API host"
  referenced_security_group_id = module.admin_access.security_group_id
  from_port                    = module.database.port
  to_port                      = module.database.port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "admin_to_loki" {
  security_group_id            = module.security.monitoring_security_group_id
  description                  = "Loki push from private admin API host"
  referenced_security_group_id = module.admin_access.security_group_id
  from_port                    = 3100
  to_port                      = 3100
  ip_protocol                  = "tcp"
}

# 전환 단계 전용. 현재 운영 BackOffice가 아직 wes-app:8080의 기존 관리자 endpoint를 쓰므로,
# admin API 배포와 BFF upstream 전환이 실제 검증되기 전에는 이 경로를 닫지 않는다.
# 후속 cleanup PR은 아래 resource와 moved block만 제거해 계획된 단일 SG rule 삭제를 만든다.
resource "aws_vpc_security_group_ingress_rule" "admin_to_public_api_transition" {
  security_group_id            = module.security.ec2_security_group_id
  description                  = "Internal admin API from wes-admin BFF"
  referenced_security_group_id = module.admin_access.security_group_id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

moved {
  from = module.security.aws_vpc_security_group_ingress_rule.ec2_app_from_admin
  to   = aws_vpc_security_group_ingress_rule.admin_to_public_api_transition
}

# 비밀번호는 state에 남기지 않기 위해 수동 SecureString으로 관리한다. 나머지 런타임 값은
# 인프라 출력에서 확정되므로 관리자 전용 prefix에 생성해 공개 앱의 OAuth/JWT 설정과 분리한다.
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
  name  = "${var.admin_parameter_prefix}/app.embedding.function-name"
  type  = "String"
  value = module.embedding.function_name
}

# 관리자 API가 남긴 trace를 같은 Loki로 전송하고, BackOffice가 동일 correlation ID의
# Grafana/Loki 링크를 만들 수 있게 조회 주소를 관리자 전용 prefix에만 제공한다.
resource "aws_ssm_parameter" "admin_logging_loki_url" {
  name  = "${var.admin_parameter_prefix}/app.logging.loki-url"
  type  = "String"
  value = module.monitoring.loki_push_url
}

resource "aws_ssm_parameter" "admin_observability_grafana_url" {
  name  = "${var.admin_parameter_prefix}/app.admin.observability.grafana-base-url"
  type  = "String"
  value = "https://${module.monitoring.fqdn}"
}

resource "aws_ssm_parameter" "admin_observability_loki_url" {
  name = "${var.admin_parameter_prefix}/app.admin.observability.loki-base-url"
  type = "String"
  # 운영자 브라우저는 VPC private Loki:3100에 직접 접근하지 않는다. Grafana가
  # provisioned datasource(uid=loki)로 server-side proxy하고 기존 Grafana 인증을 적용한다.
  value = "https://${module.monitoring.fqdn}/api/datasources/proxy/uid/loki"
}

resource "aws_ssm_parameter" "admin_server_port" {
  name  = "${var.admin_parameter_prefix}/server.port"
  type  = "String"
  value = tostring(var.admin_api_port)
}

# 같은 DB의 migration owner는 공개 wes-api 하나뿐이다. 관리자 앱은 스키마를 바꾸지 않고
# public 배포가 끝낸 migration 결과와 엔티티가 맞는지만 검사한다.
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
