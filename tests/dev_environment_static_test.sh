#!/usr/bin/env bash
set -euo pipefail

# dev 환경 스택(environments/dev)의 경계 검사. dev가 운영 리소스를 건드리거나 운영 태그·프리픽스를 쓰면 실패한다.
#   1. state가 운영과 다른 키에 있다
#   2. 운영 프리픽스(/wes/prod)는 Loki URL 읽기 하나에만 쓰인다 — 앱·DB·워커가 운영 파라미터를 보지 않는다
#   3. 이름 접두사는 wes-dev, GPU 태그는 wes-dev-score-gpu이고 SSM app.analysis.gpu.tag로 앱에 알린다
#   4. 버킷은 wes-dev-photos-* — 로컬 개발 버킷(wes-local-photos-*)과 다른 이름
#   5. ECR은 dev 전용 — analysis 모듈이 만든다(운영 리포지토리 ARN·URL을 받지 않는다)
#   6. GPU 워커는 운영 AMI를 쓰고, bootcmd로 image.env의 프리픽스·이미지를 dev 값으로 덮는다
#   7. CD 롤은 dev 브랜치만 신뢰하고 SendCommand는 wes-dev-app 태그로만
#   8. CI plan/apply가 dev 스택을 돌리고, apply는 운영 다음
#   9. 관리자 호스트는 wes-dev-admin · /wes/admin-api/dev · dev.admin 도메인이고, 운영 관리자 프리픽스·인스턴스에 닿지 않는다

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dev="$repo_root/environments/dev"
dev_main="$dev/main.tf"
dev_vars="$dev/variables.tf"
dev_roles="$dev/deploy-roles.tf"
plan_wf="$repo_root/.github/workflows/terraform-plan.yml"
apply_wf="$repo_root/.github/workflows/terraform-apply.yml"

# --- 1. state 분리 ---
rg -Fq 'key          = "dev/terraform.tfstate"' "$dev/backend.tf"

# --- 2. 운영 프리픽스 ---
rg -Fq 'default     = "/wes/dev"' "$dev_vars"
rg -Fq 'condition     = var.parameter_prefix != "/wes/prod"' "$dev_vars"
if [ "$(rg -c 'var\.prod_parameter_prefix' "$dev_main")" != "1" ]; then
  echo "dev 스택은 운영 프리픽스를 Loki URL 읽기 한 곳에서만 써야 한다" >&2
  exit 1
fi
rg -n -B1 -A1 'var\.prod_parameter_prefix' "$dev_main" | rg -Fq 'app.logging.loki-url'
if rg -n '"/wes/prod' "$dev_main" "$dev_roles"; then
  echo "dev 스택에 운영 프리픽스가 하드코딩되어 있다" >&2
  exit 1
fi

# --- 3. 이름·GPU 태그 ---
rg -Fq 'name_prefix = "wes-dev"' "$dev_main"
rg -Fq 'score_gpu_tag_name = "${local.name_prefix}-score-gpu"' "$dev_main"
rg -Fq 'score_gpu_tag_name       = local.score_gpu_tag_name' "$dev_main"
rg -Fq 'name                     = local.score_gpu_tag_name' "$dev_main"
rg -n -A3 'resource "aws_ssm_parameter" "gpu_tag"' "$dev_main" | rg -Fq 'app.analysis.gpu.tag'

# --- 4. 버킷 이름 ---
rg -n -A4 'module "storage"' "$dev_main" | rg -Fq 'name_prefix      = local.name_prefix'
rg -n -A4 'module "storage_local"' "$repo_root/main.tf" | rg -Fq 'name_prefix      = "${local.name_prefix}-local"'

# --- 5. dev 전용 ECR ---
if rg -n 'repository_url|repository_arn' "$dev_main" | rg -v 'module\.analysis\.'; then
  echo "dev 스택은 dev analysis 모듈의 ECR만 써야 한다(운영 이동 태그 보호)" >&2
  exit 1
fi
rg -Fq 'score_repository_arn     = module.analysis.repository_arns["score"]' "$dev_main"

# --- 6. GPU 워커 image.env 덮기 ---
rg -Fq 'source = "../../modules/score-gpu-workers"' "$dev_main"
rg -Fq 'bootcmd:' "$dev_main"
rg -Fq "s|^PARAMETER_PREFIX=.*|PARAMETER_PREFIX=\${var.parameter_prefix}|" "$dev_main"
rg -Fq "s|^WES_SCORE_IMAGE=.*|WES_SCORE_IMAGE=\${local.score_gpu_image}|" "$dev_main"
rg -Fq '/etc/wes-score/image.env' "$dev_main"
rg -Fq 'condition     = !startswith(var.score_gpu_image_tag, "gpu-")' "$dev_vars"

# --- 7. CD 롤 ---
rg -Fq 'subject       = "repo:${var.server_repository}:ref:refs/heads/${var.dev_branch}"' "$dev_roles"
rg -Fq 'subject       = "${var.ai_oidc_subject_prefix}:ref:refs/heads/${var.dev_branch}"' "$dev_roles"
rg -Fq 'values   = ["refs/heads/${var.dev_branch}"]' "$dev_roles"
rg -Fq 'values   = ["${local.name_prefix}-app"]' "$dev_roles"
rg -Fq 'resources = values(module.analysis.repository_arns)' "$dev_roles"
rg -Fq 'resources = values(module.analysis.function_arns)' "$dev_roles"
if rg -n 'refs/heads/main' "$dev_roles"; then
  echo "dev CD 롤이 main 브랜치를 신뢰한다" >&2
  exit 1
fi

# --- 8. CI ---
rg -Fq "dir: environments/dev" "$plan_wf"
rg -Fq -- "- 'environments/dev/**'" "$plan_wf"
rg -Fq 'needs: [detect-changes, apply-app]' "$apply_wf"
rg -Fq 'working-directory: environments/dev' "$apply_wf"
rg -Fq 'options: [app, dns, dev]' "$apply_wf"

# --- 9. 관리자 호스트 ---
dev_admin="$dev/admin.tf"
rg -Fq 'admin_instance_name                = "${local.name_prefix}-admin"' "$dev_admin"
rg -Fq 'name_prefix   = local.admin_instance_name' "$dev_admin"
rg -Fq 'default     = "/wes/admin-api/dev"' "$dev_vars"
rg -Fq 'default     = "dev.admin"' "$dev_vars"
rg -Fq 'default     = "/wes/dev-admin/tailscale-auth-key"' "$dev_vars"
rg -Fq 'values   = [local.admin_instance_name]' "$dev_roles"
rg -Fq 'subject       = "${var.backoffice_oidc_subject_prefix}:ref:refs/heads/${var.dev_branch}"' "$dev_roles"
if rg -n 'admin-api/prod|"/wes/admin/' "$dev_admin" "$dev_roles"; then
  echo "dev 관리자가 운영 관리자 프리픽스를 쓴다" >&2
  exit 1
fi

echo "dev environment static checks passed"
