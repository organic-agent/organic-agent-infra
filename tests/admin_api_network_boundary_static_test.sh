#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
security_main="$repo_root/modules/security/main.tf"
ingress_main="$repo_root/modules/ingress/main.tf"
admin_main="$repo_root/admin.tf"

rg -Fq 'resource "aws_vpc_security_group_ingress_rule" "admin_to_rds"' "$admin_main"
rg -Fq 'security_group_id            = module.security.rds_security_group_id' "$admin_main"
rg -Fq 'referenced_security_group_id = module.admin_access.security_group_id' "$admin_main"
rg -Fq 'from_port                    = module.database.port' "$admin_main"
rg -Fq 'to_port                      = module.database.port' "$admin_main"
rg -Fq 'ip_protocol                  = "tcp"' "$admin_main"
rg -Fq 'resource "aws_vpc_security_group_ingress_rule" "admin_to_loki"' "$admin_main"
rg -Fq 'security_group_id            = module.security.monitoring_security_group_id' "$admin_main"
rg -Fq 'description                  = "Loki push from private admin API host"' "$admin_main"

if rg -n 'resource "aws_vpc_security_group_ingress_rule" "ec2_app_from_admin"|admin.*app_port' \
  "$security_main"; then
  echo "the transitional admin-to-public rule must not reintroduce a module dependency cycle" >&2
  exit 1
fi

# 첫 인프라 apply에서는 기존 BackOffice upstream을 보존한다. 실제 admin API/BFF 전환 뒤
# 별도 cleanup PR에서 이 resource와 moved block만 제거한다.
rg -Fq 'resource "aws_vpc_security_group_ingress_rule" "admin_to_public_api_transition"' "$admin_main"
rg -Fq 'description                  = "Internal admin API from wes-admin BFF"' "$admin_main"
rg -Fq 'from = module.security.aws_vpc_security_group_ingress_rule.ec2_app_from_admin' "$admin_main"
rg -Fq 'to   = aws_vpc_security_group_ingress_rule.admin_to_public_api_transition' "$admin_main"

rg -Fq 'resource "aws_lb_listener_rule" "block_internal_admin"' "$ingress_main"
rg -Fq 'listener_arn = aws_lb_listener.https.arn' "$ingress_main"
rg -Fq 'priority     = 1' "$ingress_main"
rg -Fq 'type = "fixed-response"' "$ingress_main"
rg -Fq 'status_code  = "404"' "$ingress_main"
rg -Fq 'values = ["/internal/admin", "/internal/admin/*"]' "$ingress_main"

if rg -n 'admin_security_group.*0\.0\.0\.0/0|admin_to_rds.*cidr_' \
  "$security_main" "$repo_root/main.tf" "$admin_main"; then
  echo "admin-to-RDS access must use only the wes-admin security group reference" >&2
  exit 1
fi

echo "admin API network boundary static checks passed"
