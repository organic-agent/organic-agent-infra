#!/usr/bin/env bash
set -euo pipefail

# AI Lambda 셋(embedder · score · categorize) 배포 인프라(#18)의 회귀 검사.
#   1. worker 배포 역할은 AI 저장소 main의 immutable sub 하나만 신뢰하고, 세 ECR·세 함수만 다룬다
#   2. DB 서브넷에 lambda · bedrock-runtime 인터페이스 엔드포인트가 있고 private DNS가 켜져 있다
#   3. 실행 롤: embedder·score 자기 재호출, score → categorize 체인, categorize → Bedrock(프로필 + 기반 모델)
#   4. score·categorize 함수는 임베더와 같은 비동기 규칙(재시도 0·event age)과 수동 DB_PASSWORD 규칙을 따른다
#   5. wes가 읽는 SSM 파라미터 둘과 앱 인스턴스 롤의 InvokeFunction

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
oidc_main="$repo_root/modules/github-actions/main.tf"
oidc_vars="$repo_root/modules/github-actions/variables.tf"
network_main="$repo_root/modules/network/main.tf"
network_outputs="$repo_root/modules/network/outputs.tf"
analysis_main="$repo_root/modules/analysis/main.tf"
analysis_vars="$repo_root/modules/analysis/variables.tf"
root_main="$repo_root/main.tf"
root_vars="$repo_root/variables.tf"
root_outputs="$repo_root/outputs.tf"

ai_subject='repo:organic-agent@299031009/organic-agent-ai@1336874708:ref:refs/heads/main'
legacy_ai_subject='repo:organic-agent/organic-agent-ai:ref:refs/heads/main'

# --- 1. worker 배포 역할 trust: AI 저장소 main, immutable ID ---
rg -Fq 'subject       = var.worker_oidc_subject' "$oidc_main"
rg -Fq 'repository_id = var.worker_repository_id' "$oidc_main"
rg -Fq 'worker_oidc_subject    = var.ai_github_oidc_subject' "$root_main"
rg -Fq 'worker_repository_id   = var.ai_github_repository_id' "$root_main"
rg -Fq "default     = \"$ai_subject\"" "$root_vars"
rg -Fq "condition     = var.ai_github_oidc_subject == \"$ai_subject\"" "$root_vars"
rg -Fq 'default     = "1336874708"' "$root_vars"
rg -Fq 'condition     = var.ai_github_repository_id == "1336874708"' "$root_vars"

if rg -Fq "$legacy_ai_subject" "$oidc_main" "$root_main" "$root_vars"; then
  echo "legacy name-based AI OIDC subject is present" >&2
  exit 1
fi

# worker 역할이 서버 저장소 주체를 더는 신뢰하지 않는다.
if sed -n '/worker_deploy = {/,/}/p' "$oidc_main" | rg -q 'server_repository'; then
  echo "worker deploy role must not trust the server repository any more" >&2
  exit 1
fi

# --- 1. worker 배포 역할 범위: 세 ECR · 세 함수, 목록형 변수, 와일드카드 없음 ---
rg -Fq 'variable "worker_repository_arns"' "$oidc_vars"
rg -Fq 'variable "worker_function_arns"' "$oidc_vars"
rg -Fq 'type        = list(string)' "$oidc_vars"
rg -Fq 'worker_repository_arns = values(module.analysis.repository_arns)' "$root_main"
rg -Fq 'worker_function_arns   = values(module.analysis.function_arns)' "$root_main"
# 모듈 맵의 키가 곧 함수 셋이다.
for key in embedder score categorize; do
  rg -Fq "$key = \"\${var.name_prefix}-$key\"" "$analysis_main" \
    || rg -q "^ +$key +=  *\"\\\$\{var\.name_prefix\}-$key\"" "$analysis_main"
done
rg -Fq 'value       = module.github_actions.worker_deploy_role_arn' "$root_outputs"
# AI 저장소 deploy.sh는 리포지토리 URI를 describe-repositories로 찾고, update 뒤 get-function-configuration으로 검증한다.
rg -Fq '"ecr:DescribeRepositories"' "$oidc_main"
rg -Fq '"lambda:GetFunctionConfiguration"' "$oidc_main"
rg -Fq '"lambda:UpdateFunctionCode"' "$oidc_main"

# --- 2. 인터페이스 엔드포인트 ---
rg -Fq 'resource "aws_vpc_endpoint" "lambda"' "$network_main"
rg -Fq 'resource "aws_vpc_endpoint" "bedrock_runtime"' "$network_main"
rg -Fq 'service_name        = "com.amazonaws.${data.aws_region.current.name}.lambda"' "$network_main"
rg -Fq 'service_name        = "com.amazonaws.${data.aws_region.current.name}.bedrock-runtime"' "$network_main"
[ "$(rg -c 'vpc_endpoint_type   = "Interface"' "$network_main")" -eq 2 ]
[ "$(rg -c 'private_dns_enabled = true' "$network_main")" -eq 2 ]
rg -Fq 'resource "aws_security_group" "vpc_endpoints"' "$network_main"
rg -Fq 'cidr_ipv4         = aws_vpc.this.cidr_block' "$network_main"
rg -Fq 'from_port         = 443' "$network_main"
# 함수를 만드는 쪽이 엔드포인트 생성을 기다린다.
rg -Fq 'aws_vpc_endpoint.lambda,' "$network_outputs"
rg -Fq 'aws_vpc_endpoint.bedrock_runtime,' "$network_outputs"
# 게이트웨이 엔드포인트는 그대로 하나, 퍼블릭 라우트 테이블에는 붙지 않는다.
rg -Fq 'route_table_ids   = [aws_route_table.db.id]' "$network_main"

# --- 3. IAM: 자기 재호출·체인·Bedrock ---
rg -Fq 'sid       = "ReinvokeSelf"' "$analysis_main"
rg -Fq 'resources = [local.function_arns.embedder]' "$analysis_main"
rg -Fq 'sid       = "ConnectAsEmbedder"' "$analysis_main"
rg -Fq 'sid       = "ReinvokeSelfAndChainCategorize"' "$analysis_main"
rg -Fq 'resources = [local.function_arns.score, local.function_arns.categorize]' "$analysis_main"
rg -Fq 'sid     = "InvokeNamingModel"' "$analysis_main"
rg -Fq 'actions = ["bedrock:InvokeModel"]' "$analysis_main"
rg -Fq ':inference-profile/${var.bedrock_model_id}' "$analysis_main"
rg -Fq 'foundation-model/${local.bedrock_foundation_model_id}' "$analysis_main"
rg -Fq 'CATEGORIZE_FUNCTION_NAME = local.function_names.categorize' "$analysis_main"

# categorize에는 Lambda 호출 권한이, score에는 Bedrock 권한이 없다.
if sed -n '/data "aws_iam_policy_document" "categorize"/,/^}/p' "$analysis_main" | rg -q 'lambda:'; then
  echo "categorize execution role must not invoke Lambda" >&2
  exit 1
fi
if sed -n '/data "aws_iam_policy_document" "score"/,/^}/p' "$analysis_main" | rg -q 'bedrock:'; then
  echo "score execution role must not call Bedrock" >&2
  exit 1
fi
if rg -n '"bedrock:\*"|"lambda:\*"|"s3:\*"|resources = \["\*"\]' "$analysis_main"; then
  echo "analysis execution roles must stay on exact resources and actions" >&2
  exit 1
fi

# --- 4. 함수 규칙: 셋이 같은 비동기·비밀번호 규칙, 함수마다 다른 크기. embedder는 주소만 옮기고 재생성하지 않는다 ---
for r in aws_ecr_repository.this aws_ecr_lifecycle_policy.this aws_iam_role.this aws_iam_role_policy_attachment.vpc_access \
         aws_iam_role_policy.this aws_cloudwatch_log_group.this aws_lambda_function.this aws_lambda_function_event_invoke_config.this \
         aws_cloudwatch_metric_alarm.async_event_age aws_cloudwatch_metric_alarm.async_events_dropped aws_ssm_parameter.function_name; do
  rg -Fq "from = module.embedding.$r" "$root_main"
  rg -Fq "to   = module.analysis.$r[\"embedder\"]" "$root_main"
done
[ ! -d "$repo_root/modules/embedding" ]
rg -Fq 'policy_name    = "read-photos-and-connect-db"' "$analysis_main"
rg -Fq 'maximum_retry_attempts       = 0' "$analysis_main"
rg -Fq 'maximum_event_age_in_seconds = var.async_event_max_age_seconds' "$analysis_main"
rg -Fq 'reserved_concurrent_executions = each.value.reserved_concurrency' "$analysis_main"
rg -Fq 'environment[0].variables["DB_PASSWORD"],' "$analysis_main"
rg -Fq 'image_uri,' "$analysis_main"
rg -Fq 'timeout = 900' "$analysis_main"
rg -Fq 'size = each.value.ephemeral_storage_mb' "$analysis_main"
rg -Fq 'default     = 8192' "$analysis_vars"
rg -Fq 'default     = 10240' "$analysis_vars"
rg -Fq 'default     = 3008' "$analysis_vars"
rg -Fq 'default     = "photoselect"' "$analysis_vars"
rg -Fq 'default     = "global.anthropic.claude-sonnet-4-6"' "$analysis_vars"
rg -Fq 'metric_name         = "AsyncEventAge"' "$analysis_main"
rg -Fq 'metric_name         = "AsyncEventsDropped"' "$analysis_main"

if rg -n 'DB_PASSWORD\s*=' "$analysis_main"; then
  echo "DB_PASSWORD must never be set by Terraform" >&2
  exit 1
fi

# --- 5. wes 연결: 파라미터 이름은 서버의 app.analysis.{score,categorize}-function-name, 앱 롤의 InvokeFunction ---
rg -Fq 'parameter_name = "app.analysis.embedder-function-name"' "$analysis_main"
rg -Fq 'name  = "${var.parameter_prefix}/app.analysis.gpu.enabled"' "$analysis_main"
rg -Fq 'value = var.gpu_score_enabled ? "true" : "false"' "$analysis_main"
rg -Fq 'app.analysis.embedder-function-name' "$repo_root/admin.tf"
# wes V16부터 옛 키는 아무도 읽지 않는다 — 남겨 두면 "있는데 왜 503"으로 헷갈린다.
if rg -n '^\s*[^#]*app\.embedding\.function-name' "$analysis_main" "$repo_root/admin.tf" "$root_main"; then
  echo "legacy app.embedding.function-name parameter must be gone (wes V16 reads app.analysis.embedder-function-name)" >&2
  exit 1
fi
rg -Fq 'parameter_name       = "app.analysis.score-function-name"' "$analysis_main"
rg -Fq 'parameter_name       = "app.analysis.categorize-function-name"' "$analysis_main"
rg -Fq 'name  = "${var.parameter_prefix}/${each.value.parameter_name}"' "$analysis_main"
rg -Fq 'sid       = "InvokeAnalysisFunctions"' "$analysis_main"
rg -Fq 'role   = var.app_role_name' "$analysis_main"
rg -Fq 'app_role_name     = module.compute.instance_role_name' "$root_main"
rg -Fq 'security_group_id = module.security.embedder_security_group_id' "$root_main"

echo "analysis lambdas static checks passed"
