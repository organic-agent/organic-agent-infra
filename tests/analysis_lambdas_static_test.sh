#!/usr/bin/env bash
set -euo pipefail

# AI Lambda 셋(embedder · score · categorize) 배포 인프라(#18)의 회귀 검사.
#   1. worker 배포 역할은 AI 저장소 main의 immutable sub 하나만 신뢰하고, 세 ECR·세 함수만 다룬다
#   2. Bedrock은 다른 리전의 엔드포인트 전용 VPC로 피어링을 타고 나간다(#71): 엔드포인트·양방향 라우트·프라이빗 호스티드 존. lambda 엔드포인트는 없다(#57)
#   3. 실행 롤: embedder·score에 lambda:InvokeFunction 없음(재호출·체인은 v2에서 wes 소유), categorize → Bedrock(Bedrock 리전의 프로필 + 기반 모델)
#   4. score·categorize 함수는 임베더와 같은 비동기 규칙(재시도 0·event age)과 수동 DB_PASSWORD 규칙을 따른다
#   5. wes가 읽는 SSM 파라미터 둘과 앱 인스턴스 롤의 InvokeFunction

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
oidc_main="$repo_root/modules/github-actions/main.tf"
oidc_vars="$repo_root/modules/github-actions/variables.tf"
network_main="$repo_root/modules/network/main.tf"
network_bedrock="$repo_root/modules/network/bedrock.tf"
compute_main="$repo_root/modules/compute/main.tf"
root_providers="$repo_root/providers.tf"
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

# --- 2. Bedrock 경로: 다른 리전의 엔드포인트 전용 VPC + 피어링 + 프라이빗 호스티드 존 (#71) ---
# 엔드포인트 쪽 리소스는 전부 aws.bedrock 프로바이더(= var.bedrock_region)로 만들어진다.
rg -Fq 'alias  = "bedrock"' "$root_providers"
rg -Fq 'region = var.bedrock_region' "$root_providers"
rg -Fq 'aws.bedrock = aws.bedrock' "$root_main"
rg -Fq 'configuration_aliases = [aws.bedrock]' "$repo_root/modules/network/versions.tf"
for r in 'aws_vpc" "bedrock"' 'aws_subnet" "bedrock"' 'aws_vpc_peering_connection_accepter" "bedrock"' \
         'aws_route_table" "bedrock"' 'aws_route" "bedrock_to_main"' 'aws_security_group" "bedrock_endpoint"' \
         'aws_vpc_endpoint" "bedrock"'; do
  sed -n "/resource \"$r/,/^}/p" "$network_bedrock" | rg -Fq 'provider = aws.bedrock' \
    || { echo "$r must be created in the Bedrock region (provider = aws.bedrock)" >&2; exit 1; }
done
# 인터페이스 엔드포인트는 하나뿐이고(ENI당 시간 과금) private DNS는 끈다 — 이름 풀이는 서울 VPC의 호스티드 존 몫이다.
[ "$(rg -c 'vpc_endpoint_type   = "Interface"' "$network_bedrock")" -eq 1 ]
rg -Fq 'private_dns_enabled = false' "$network_bedrock"
rg -Fq 'subnet_ids          = [aws_subnet.bedrock.id]' "$network_bedrock"
rg -Fq 'cidr_ipv4         = aws_vpc.this.cidr_block' "$network_bedrock"
rg -Fq 'from_port         = 443' "$network_bedrock"
# 서울 리전에는 인터페이스 엔드포인트가 남지 않는다 — 남으면 쓰이지 않는 ENI에 월 $11을 낸다.
if rg -n '^\s*[^#]*(vpc_endpoint_type\s*=\s*"Interface"|private_dns_enabled)' "$network_main"; then
  echo "no interface endpoint may remain in the stack region — Bedrock goes over peering (#71)" >&2
  exit 1
fi
# 피어링은 수락된 뒤에만 라우트를 걸 수 있다: 세 라우트 모두 accepter의 id를 쓴다. 퍼블릭(앱 EC2)·DB(Lambda)·되돌아오는 길.
[ "$(rg -c 'vpc_peering_connection_id = aws_vpc_peering_connection_accepter.bedrock.id' "$network_bedrock")" -eq 2 ]
rg -Fq 'vpc_peering_connection_id = aws_vpc_peering_connection_accepter.bedrock.id' "$network_main"
rg -Fq 'route_table_id            = aws_route_table.db.id' "$network_bedrock"
rg -Fq 'destination_cidr_block    = aws_vpc.this.cidr_block' "$network_bedrock"
# 호스티드 존이 SDK 기본 호스트네임을 엔드포인트로 돌린다 — 함수·앱 코드에 엔드포인트 URL이 없다.
rg -Fq 'name    = "bedrock-runtime.${data.aws_region.bedrock.name}.amazonaws.com"' "$network_bedrock"
rg -Fq 'vpc_id = aws_vpc.this.id' "$network_bedrock"
rg -Fq 'name                   = aws_vpc_endpoint.bedrock.dns_entry[0].dns_name' "$network_bedrock"
# DB 서브넷에는 여전히 인터넷 경로가 없다. 0.0.0.0/0은 퍼블릭 라우트 테이블의 IGW 하나뿐이다.
[ "$(rg -c '"0\.0\.0\.0/0"' "$network_main")" -eq 1 ]
if rg -n 'aws_nat_gateway|"0\.0\.0\.0/0"' "$network_bedrock"; then
  echo "the Bedrock path must not open an internet route" >&2
  exit 1
fi
# 함수를 만드는 쪽이 경로(라우트·레코드) 생성을 기다린다.
rg -Fq 'aws_route.db_to_bedrock,' "$network_outputs"
rg -Fq 'aws_route53_record.bedrock_runtime,' "$network_outputs"
# lambda 엔드포인트(ENI당 시간 과금)는 Lambda 간 호출이 사라진 v2에서 뺐다. 되살아나면 비용 근거를 다시 써야 한다.
if rg -n '^\s*[^#]*aws_vpc_endpoint"? "?lambda' "$network_main" "$network_bedrock" "$network_outputs" "$root_outputs"; then
  echo "lambda interface endpoint must stay removed (#57) — Lambda-to-Lambda calls no longer exist" >&2
  exit 1
fi
# 게이트웨이 엔드포인트는 그대로 하나, 퍼블릭 라우트 테이블에는 붙지 않는다.
rg -Fq 'route_table_ids   = [aws_route_table.db.id]' "$network_main"

# --- 3. IAM: 자기 재호출·체인·Bedrock ---
rg -Fq 'sid       = "ConnectAsEmbedder"' "$analysis_main"
# embedder·score 실행 롤에는 lambda: 액션이 없다 — 자기 재호출·샤드 팬아웃·categorize 체인은 v2에서 wes가 가져갔다(#57).
for doc in embedder score; do
  if sed -n "/data \"aws_iam_policy_document\" \"$doc\"/,/^}/p" "$analysis_main" | rg -q 'lambda:'; then
    echo "$doc execution role must not invoke Lambda (v2: wes owns reinvoke/chain)" >&2
    exit 1
  fi
done
rg -Fq 'sid     = "InvokeNamingModel"' "$analysis_main"
rg -Fq 'actions = ["bedrock:InvokeModel"]' "$analysis_main"
# 프로필 ARN의 리전은 스택 리전이 아니라 Bedrock 리전이다. Lambda·앱 롤, Lambda 환경변수, 앱 파라미터가 같은 변수를 쓴다.
rg -Fq 'arn:aws:bedrock:${var.bedrock_region}:${local.account_id}:inference-profile/${var.bedrock_model_id}' "$analysis_main"
rg -Fq 'arn:aws:bedrock:${var.bedrock_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_id}' "$compute_main"
rg -Fq 'BEDROCK_REGION   = var.bedrock_region' "$analysis_main"
rg -Fq 'name  = "${var.parameter_prefix}/app.llm.region"' "$root_main"
rg -Fq 'name  = "${var.parameter_prefix}/app.llm.model-id"' "$root_main"
rg -Fq 'foundation-model/${local.bedrock_foundation_model_id}' "$analysis_main"
if rg -n '^\s*[^#]*CATEGORIZE_FUNCTION_NAME' "$analysis_main"; then
  echo "score no longer chains categorize — CATEGORIZE_FUNCTION_NAME must be gone (#57)" >&2
  exit 1
fi

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
rg -Fq 'default     = "us.anthropic.claude-sonnet-4-6"' "$analysis_vars"
rg -Fq 'default     = "us.anthropic.claude-sonnet-4-6"' "$root_vars"
# 조직 SCP가 `global.` 프로필을 거부한다(#71). 기본값으로 되돌아오면 Bedrock 호출이 전부 AccessDenied다.
if rg -n '^\s*default\s*=\s*"global\.' "$analysis_vars" "$root_vars"; then
  echo "global. inference profiles are denied by the organization SCP (#71)" >&2
  exit 1
fi
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
