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

# BackOffice는 같은 호스트의 Docker internal network를 통해 wes-admin-api만 호출한다.
# 전환용 wes-admin -> 공개 API SG 규칙과 그 state move는 최종 구성에 남지 않아야 한다.
if rg -n 'resource "aws_vpc_security_group_ingress_rule" "ec2_app_from_admin"|admin.*app_port' \
  "$security_main" || \
  rg -n 'admin_to_public_api_transition|Internal admin API from wes-admin BFF|module\.security\.aws_vpc_security_group_ingress_rule\.ec2_app_from_admin' \
    "$admin_main"; then
  echo "the admin-to-public API transition rule must not remain" >&2
  exit 1
fi

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
