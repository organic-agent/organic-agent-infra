#!/usr/bin/env bash
set -euo pipefail

# score GPU 워커 풀(modules/score-gpu)의 회귀 검사 — 계획 docs/pipeline-v2-infra-plan.md §7.
# PR-3b(AMI 파이프라인)에 해당하는 항목만 있다. 인스턴스·SG·워커 롤·알람 항목은 PR-3c에서 이 파일에 더한다.
#   1. 서비스 연결 역할 둘(imagebuilder · events)이 코드로 있고, tf_apply 문장은 그 두 ARN으로 한정(§7-8)
#   2. 부모 이미지는 Image Builder 관리 이미지 `x.x.x` — data "aws_ami" most_recent 금지(§7-6의 정신: 빌드마다 replace 금지)
#   3. 빌드 인스턴스: 실패 시 종료, IMDSv2 강제, 롤 이름은 name_prefix 접두사(tf_apply IAM 울타리·PassRole 범위)
#   4. 파이프라인은 수동 실행 — schedule 없음, test 단계 켜짐
#   5. 컴포넌트: 드라이버 브랜치 고정, nvidia-smi 검증, 셸 안에 `{{ }}` 없음(Image Builder 체이닝 식과 충돌), permissions는 문자열
#   6. 워커 유닛·스크립트: SSM은 정확히 세 파라미터, 프리픽스 와일드카드 없음, 비밀번호는 /run(tmpfs)에만, --gpus all, verify-full,
#      AMI에 굽는 image.env에 비밀번호 없음, 기동 실패 시 failsafe(OnFailure)로 자기 정지
#   7. ECR score 라이프사이클에 gpu- 접두사 최근 3개 규칙(§7-7), 이동 태그 gpu는 규칙 밖
#   8. `arn:aws:automate:` EC2 액션 ARN은 modules/score-gpu 밖 어디에도 없다(§7-10) — 3b에는 아직 안에도 없다
#   9. 루트 배선: module "score_gpu"가 score 리포지토리 URL을 받고, 파이프라인 ARN 출력이 있다

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mod="$repo_root/modules/score-gpu"
mod_main="$mod/main.tf"
mod_vars="$mod/variables.tf"
component="$mod/components/nvidia-docker.yaml.tftpl"
env_script="$mod/files/wes-score-env.sh"
pull_script="$mod/files/wes-score-pull.sh"
failsafe_script="$mod/files/wes-score-failsafe.sh"
unit="$mod/files/wes-score.service"
failsafe_unit="$mod/files/wes-score-failsafe.service"
oidc_main="$repo_root/modules/github-actions/main.tf"
analysis_main="$repo_root/modules/analysis/main.tf"
root_main="$repo_root/main.tf"
root_outputs="$repo_root/outputs.tf"

# --- 1. 서비스 연결 역할 ---
rg -Fq 'resource "aws_iam_service_linked_role" "imagebuilder"' "$mod_main"
rg -Fq 'aws_service_name = "imagebuilder.amazonaws.com"' "$mod_main"
rg -Fq 'resource "aws_iam_service_linked_role" "cloudwatch_events"' "$mod_main"
rg -Fq 'aws_service_name = "events.amazonaws.com"' "$mod_main"
rg -Fq 'sid = "ServiceLinkedRolesForScoreGpu"' "$oidc_main"
rg -Fq 'role/aws-service-role/imagebuilder.amazonaws.com/AWSServiceRoleForImageBuilder' "$oidc_main"
rg -Fq 'role/aws-service-role/events.amazonaws.com/AWSServiceRoleForCloudWatchEvents' "$oidc_main"
if rg -n 'aws-service-role/[^"]*\*' "$oidc_main" "$mod_main"; then
  echo "service-linked role ARN is wildcarded" >&2
  exit 1
fi

# --- 2. 부모 이미지 ---
rg -Fq 'aws:image/amazon-linux-2023-x86/x.x.x' "$mod_main"
rg -Fq 'parent_image = local.parent_image' "$mod_main"
if rg -n '^\s*data "aws_ami"|^\s*most_recent\s*=' "$mod_main"; then
  echo "score-gpu must not resolve AMIs with a most_recent data source (replace on every build)" >&2
  exit 1
fi

# --- 3. 빌드 인스턴스 ---
rg -Fq 'terminate_instance_on_failure = true' "$mod_main"
rg -Fq 'http_tokens                 = "required"' "$mod_main"
rg -Fq 'name        = "${var.name_prefix}-score-gpu"' "$mod_main"
rg -Fq 'name_prefix        = "${local.name}-builder-"' "$mod_main"
rg -Fq 'name_prefix = "${local.name}-builder-"' "$mod_main"
rg -Fq 'policy_arn = "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder"' "$mod_main"
rg -Fq 'policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"' "$mod_main"
if rg -n '^\s*ingress\s*\{|aws_security_group_rule|aws_vpc_security_group_ingress_rule' "$mod_main"; then
  echo "score-gpu builder security group must have no ingress" >&2
  exit 1
fi

# --- 4. 파이프라인 ---
rg -Fq 'resource "aws_imagebuilder_image_pipeline" "this"' "$mod_main"
rg -Fq 'image_tests_enabled = true' "$mod_main"
if rg -n '^\s*schedule\s*\{' "$mod_main"; then
  echo "score-gpu pipeline must be manual (no schedule block)" >&2
  exit 1
fi

# --- 5. 컴포넌트 ---
rg -Fq 'dnf install -y nvidia-release' "$component"
rg -Fq 'dnf install -y "nvidia-driver-cuda-${nvidia_driver_branch}.*"' "$component"
rg -Fq 'nvidia-smi --query-gpu=driver_version' "$component"
rg -Fq 'dnf install -y nvidia-container-toolkit' "$component"
rg -Fq 'nvidia-ctk runtime configure --runtime=docker' "$component"
rg -Fq 'systemctl enable wes-score.service' "$component"
rg -Fq 'default     = "580"' "$mod_vars"
if rg -n '^\s*[^#].*\{\{' "$component"; then
  echo "component shell must not contain {{ }} (Image Builder parses it as a chaining expression)" >&2
  exit 1
fi
if rg -n 'permissions: [0-9]' "$component"; then
  echo "CreateFile permissions must be quoted strings" >&2
  exit 1
fi
# 코드 이미지는 AMI에 굽지 않는다(결정 B) — 컴포넌트에 docker pull 없음.
if rg -n 'docker pull' "$component"; then
  echo "component must not pull the worker image (it is pulled at boot, decision B)" >&2
  exit 1
fi

# --- 6. 워커 유닛·스크립트 ---
rg -Fq '${PARAMETER_PREFIX}/spring.datasource.url' "$env_script"
rg -Fq '${PARAMETER_PREFIX}/photoselect.db.password' "$env_script"
rg -Fq '${PARAMETER_PREFIX}/app.storage.bucket' "$env_script"
if [ "$(rg -c 'aws ssm get-parameter' "$env_script")" != "1" ] || rg -n 'get-parameters-by-path|PARAMETER_PREFIX}/?\*' "$env_script"; then
  echo "env script must read exactly three named parameters, never the prefix" >&2
  exit 1
fi
rg -Fq 'umask 077' "$env_script"
rg -Fq 'mv "$tmp" /run/wes-score.env' "$env_script"
rg -Fq 'ExecStartPre=/usr/local/bin/wes-score-env.sh' "$unit"
rg -Fq 'ExecStartPre=/usr/local/bin/wes-score-pull.sh' "$unit"
rg -Fq -- '--gpus all' "$unit"
rg -Fq -- '--env-file /run/wes-score.env' "$unit"
rg -Fq -- '-e DB_USER=photoselect' "$unit"
rg -Fq -- '-e DB_SSLMODE=verify-full' "$unit"
rg -Fq -- '-e WORKER_IDLE_STOP_SECONDS=${WORKER_IDLE_STOP_SECONDS}' "$unit"
rg -Fq 'OnFailure=wes-score-failsafe.service' "$unit"
rg -Fq 'ExecStopPost=-/bin/rm -f /run/wes-score.env' "$unit"
rg -Fq 'ExecStart=/usr/local/bin/wes-score-failsafe.sh' "$failsafe_unit"
rg -Fq 'aws ec2 stop-instances' "$failsafe_script"
rg -Fq 'X-aws-ec2-metadata-token' "$failsafe_script"
rg -Fq 'docker pull --quiet "$WES_SCORE_IMAGE"' "$pull_script"
# AMI에 구워지는 image.env에는 비밀이 없다.
if rg -n -A6 'path: /etc/wes-score/image.env' "$component" | rg -qi 'password|secret'; then
  echo "image.env baked into the AMI must not contain secrets" >&2
  exit 1
fi

# --- 7. ECR 라이프사이클 ---
rg -Fq 'tagPrefixList = ["gpu-"]' "$analysis_main"
rg -Fq 'each.key == "score" ?' "$analysis_main"
rg -Fq 'countType     = "imageCountMoreThan"' "$analysis_main"
if rg -n 'tagPrefixList = \["gpu"\]' "$analysis_main"; then
  echo "the moving tag gpu must not be subject to expiry" >&2
  exit 1
fi

# --- 8. EC2 정지 액션 ARN은 score-gpu 밖에 없다 ---
if rg -n 'arn:aws:automate:' "$repo_root" --glob '!modules/score-gpu/**' --glob '!docs/**' --glob '!tests/**' --glob '!.terraform/**'; then
  echo "EC2 stop alarm action must only exist in modules/score-gpu" >&2
  exit 1
fi

# --- 9. 루트 배선 ---
rg -Fq 'module "score_gpu"' "$root_main"
rg -Fq 'score_repository_url = module.analysis.repository_urls["score"]' "$root_main"
rg -Fq 'subnet_id            = module.network.public_subnet_ids[0]' "$root_main"
rg -Fq 'value       = module.score_gpu.image_pipeline_arn' "$root_outputs"

echo "score-gpu static checks passed"
