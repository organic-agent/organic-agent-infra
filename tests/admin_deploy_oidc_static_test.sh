#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
module_main="$repo_root/modules/github-actions/main.tf"
expected_subject='repo:organic-agent@299031009/organic-agent-backoffice@1344578659:ref:refs/heads/main'
legacy_subject='repo:organic-agent/organic-agent-backoffice:ref:refs/heads/main'

rg -Fq 'subject       = var.admin_oidc_subject' "$module_main"
rg -Fq 'subject       = "repo:${var.server_repository}:ref:refs/heads/main"' "$module_main"
rg -Fq 'repository_id = var.server_repository_id' "$module_main"
rg -Fq 'variable = "token.actions.githubusercontent.com:repository_owner_id"' "$module_main"
rg -Fq 'variable = "token.actions.githubusercontent.com:repository_id"' "$module_main"
rg -Fq 'variable = "token.actions.githubusercontent.com:ref"' "$module_main"
rg -Fq 'resource "aws_iam_role" "admin_deploy"' "$module_main"
rg -Fq 'resource "aws_iam_role_policy" "admin_deploy"' "$module_main"
rg -Fq 'resource "aws_iam_role" "admin_api_deploy"' "$module_main"
rg -Fq 'resource "aws_iam_role_policy" "admin_api_deploy"' "$module_main"
rg -Fq 'values   = [var.admin_instance_name]' "$module_main"
rg -Fq 'resources = ["arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"]' "$module_main"
rg -q 'admin_oidc_subject[[:space:]]*=[[:space:]]*var\.admin_github_oidc_subject' "$repo_root/main.tf"
rg -q 'admin_instance_name[[:space:]]*=[[:space:]]*"\$\{local\.name_prefix\}-admin"' "$repo_root/main.tf"
rg -Fq "default     = \"$expected_subject\"" "$repo_root/variables.tf"
rg -Fq "condition     = var.admin_github_oidc_subject == \"$expected_subject\"" "$repo_root/variables.tf"
rg -Fq 'default     = "1297201474"' "$repo_root/variables.tf"
rg -Fq 'default     = "1344578659"' "$repo_root/variables.tf"
rg -Fq 'default     = "299031009"' "$repo_root/variables.tf"
rg -Fq 'value       = module.github_actions.admin_deploy_role_arn' "$repo_root/outputs.tf"
rg -Fq 'value       = module.github_actions.admin_api_deploy_role_arn' "$repo_root/outputs.tf"

if rg -Fq "$legacy_subject" "$module_main" "$repo_root/main.tf" "$repo_root/variables.tf"; then
  echo "legacy name-based admin OIDC subject is still present" >&2
  exit 1
fi

if rg -n 'admin_oidc_subject.*\*|admin_github_oidc_subject.*\*|admin_instance_name.*\*|admin_api_deploy.*\*' \
  "$module_main" "$repo_root/main.tf" "$repo_root/variables.tf"; then
  echo "admin deploy trust or target scope is broader than intended" >&2
  exit 1
fi

echo "admin deploy OIDC static checks passed"
