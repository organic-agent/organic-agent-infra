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

# 변수 블록 하나의 default 값만 뽑는다. 파일 전체를 고정 문자열로 찍으면(예: `default     = 4`) 값이 바뀔 때마다
# 테스트가 낡고, 부분 매칭이라 다른 변수의 4096 같은 값에도 헛 통과한다(#36).
variable_default() {
  # `\s`는 BSD sed(macOS)가 모른다 — POSIX 클래스로. rg는 둘 다 안다.
  sed -n "/^variable \"$1\" {/,/^}/p" "$2" | rg -o 'default\s*=\s*\S+' | head -1 | sed -E 's/default[[:space:]]*=[[:space:]]*//'
}

# DB outbox가 재시도를 소유하므로 Lambda 서비스 재시도는 끄고, 15분 runtime+5분 queue로 제한한다.
rg -Fq 'resource "aws_lambda_function_event_invoke_config" "this"' "$analysis_main"
rg -Fq 'maximum_retry_attempts       = 0' "$analysis_main"
rg -Fq 'maximum_event_age_in_seconds = var.async_event_max_age_seconds' "$analysis_main"
[ "$(variable_default async_event_max_age_seconds "$analysis_vars")" = "1200" ]

# 예약 동시성은 갤러리 샤딩의 샤드 상한(MAX_SHARDS=32)과 같아야 한다 — embedder·score 둘 다(#30·#32).
# 값 자체는 변수 블록에서 읽고, 상한(64 = advisory lock stride)은 validation 메시지로 확인한다.
rg -Fq 'reserved_concurrent_executions = each.value.reserved_concurrency' "$analysis_main"
rg -Fq 'reserved_concurrency = var.embedder_reserved_concurrent_executions' "$analysis_main"
rg -Fq 'reserved_concurrency = var.score_reserved_concurrent_executions' "$analysis_main"
[ "$(variable_default embedder_reserved_concurrent_executions "$analysis_vars")" = "32" ]
[ "$(variable_default score_reserved_concurrent_executions "$analysis_vars")" = "32" ]
# 루트는 score 만 변수로 노출한다. embedder 는 모듈 기본값을 그대로 쓴다(main.tf 의 module "analysis" 인자 참고).
[ "$(variable_default score_reserved_concurrent_executions "$repo_root/variables.tf")" = "32" ]
rg -Fq 'embedder_reserved_concurrent_executions는 1~64 사이여야 합니다' "$analysis_vars"
rg -Fq 'score_reserved_concurrent_executions는 1~64 사이여야 합니다' "$analysis_vars"
rg -Fq 'metric_name         = "AsyncEventAge"' "$analysis_main"
rg -Fq 'threshold           = 600000' "$analysis_main"
rg -Fq 'metric_name         = "AsyncEventsDropped"' "$analysis_main"

echo "worker deploy and async invoke static checks passed"
