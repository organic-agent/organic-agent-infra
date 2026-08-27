#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

rg -Fq 'default     = "/wes/admin-api/prod"' "$repo_root/variables.tf"
rg -Fq 'default     = "wes_admin_api"' "$repo_root/variables.tf"
rg -Fq 'resource "aws_ssm_parameter" "admin_datasource_url"' "$repo_root/admin.tf"
rg -Fq 'resource "aws_ssm_parameter" "admin_datasource_username"' "$repo_root/admin.tf"
rg -Fq 'resource "aws_ssm_parameter" "admin_photo_bucket"' "$repo_root/admin.tf"
rg -Fq 'resource "aws_ssm_parameter" "admin_embedding_function"' "$repo_root/admin.tf"
rg -Fq 'resource "aws_ssm_parameter" "admin_logging_loki_url"' "$repo_root/admin.tf"
rg -Fq 'resource "aws_ssm_parameter" "admin_observability_grafana_url"' "$repo_root/admin.tf"
rg -Fq 'resource "aws_ssm_parameter" "admin_observability_loki_url"' "$repo_root/admin.tf"
rg -Fq 'api/datasources/proxy/uid/loki' "$repo_root/admin.tf"
rg -Fq 'value = module.monitoring.loki_push_url' "$repo_root/admin.tf"
rg -Fq 'value = "https://${module.monitoring.fqdn}"' "$repo_root/admin.tf"
rg -Fq 'resource "aws_ssm_parameter" "admin_server_port"' "$repo_root/admin.tf"
rg -Fq 'resource "aws_ssm_parameter" "admin_flyway_disabled"' "$repo_root/admin.tf"
rg -Fq 'resource "aws_ssm_parameter" "admin_hibernate_validate"' "$repo_root/admin.tf"
rg -Fq 'value = "false"' "$repo_root/admin.tf"
rg -Fq 'value = "validate"' "$repo_root/admin.tf"
rg -Fq 'admin_db_password_parameter_name' "$repo_root/admin.tf"
rg -Fq 'value       = local.admin_db_password_parameter_name' "$repo_root/outputs.tf"

if rg -n 'resource "aws_ssm_parameter" "admin.*password|admin_db_password.*value[[:space:]]*=' \
  "$repo_root/admin.tf" "$repo_root/variables.tf"; then
  echo "admin DB password must remain a manually managed SecureString and never enter Terraform state" >&2
  exit 1
fi

echo "admin runtime parameter static checks passed"
