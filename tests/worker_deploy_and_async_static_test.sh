#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
oidc_main="$repo_root/modules/github-actions/main.tf"
analysis_main="$repo_root/modules/analysis/main.tf"
analysis_vars="$repo_root/modules/analysis/variables.tf"

# EC2 배포 역할을 넓히지 않고 worker 역할을 별도로 둔다. 역할은 정확한 ECR·Lambda ARN 목록만 받는다.
rg -Fq 'resource "aws_iam_role" "worker_deploy"' "$oidc_main"
rg -Fq 'resource "aws_iam_role_policy" "worker_deploy"' "$oidc_main"
rg -Fq 'assume_role_policy = data.aws_iam_policy_document.assume["worker_deploy"].json' "$oidc_main"
rg -Fq 'resources = var.worker_repository_arns' "$oidc_main"
rg -Fq 'resources = var.worker_function_arns' "$oidc_main"
rg -Fq '"ecr:PutImage"' "$oidc_main"
rg -Fq '"ecr:DescribeImageScanFindings"' "$oidc_main"
rg -Fq '"lambda:UpdateFunctionCode"' "$oidc_main"
rg -Fq '"lambda:GetFunctionConfiguration"' "$oidc_main"

if rg -n '"ecr:\*"|"lambda:\*"|worker_repository_arns.*\*|worker_function_arns.*\*' "$oidc_main"; then
  echo "worker deploy role must stay on exact ECR/Lambda resources and actions" >&2
  exit 1
fi

if sed -n '/data "aws_iam_policy_document" "deploy"/,/resource "aws_iam_role_policy" "deploy"/p' "$oidc_main" \
  | rg -q 'ecr:|lambda:'; then
  echo "public EC2 deploy role must not gain worker permissions" >&2
  exit 1
fi

if sed -n '/data "aws_iam_policy_document" "admin_deploy"/,/resource "aws_iam_role_policy" "admin_deploy"/p' "$oidc_main" \
  | rg -q 'ecr:|lambda:'; then
  echo "admin EC2 deploy role must not gain worker permissions" >&2
  exit 1
fi

rg -Fq 'value       = module.github_actions.worker_deploy_role_arn' "$repo_root/outputs.tf"

# environment를 선언한 tf_apply job의 실제 sub/context와 immutable repository ID를 모두 검사한다.
rg -Fq 'subject       = "repo:${var.infra_repository}:environment:production"' "$oidc_main"
rg -Fq 'repository_id = var.infra_repository_id' "$oidc_main"
rg -Fq 'environment   = "production"' "$oidc_main"
rg -Fq 'default     = "1288279318"' "$repo_root/variables.tf"
rg -Fq 'environment: production' "$repo_root/.github/workflows/terraform-apply.yml"

# DB outbox가 재시도를 소유하므로 Lambda 서비스 재시도는 끄고, 15분 runtime+5분 queue로 제한한다.
rg -Fq 'resource "aws_lambda_function_event_invoke_config" "this"' "$analysis_main"
rg -Fq 'maximum_retry_attempts       = 0' "$analysis_main"
rg -Fq 'maximum_event_age_in_seconds = var.async_event_max_age_seconds' "$analysis_main"
rg -Fq 'default     = 1200' "$analysis_vars"
rg -Fq 'reserved_concurrent_executions = each.value.reserved_concurrency' "$analysis_main"
rg -Fq 'reserved_concurrency = var.embedder_reserved_concurrent_executions' "$analysis_main"
rg -Fq 'default     = 4' "$analysis_vars"
rg -Fq 'metric_name         = "AsyncEventAge"' "$analysis_main"
rg -Fq 'threshold           = 600000' "$analysis_main"
rg -Fq 'metric_name         = "AsyncEventsDropped"' "$analysis_main"

echo "worker deploy and async invoke static checks passed"
