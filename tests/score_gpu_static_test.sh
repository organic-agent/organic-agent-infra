#!/usr/bin/env bash
set -euo pipefail

# score GPU 워커 풀(modules/score-gpu)의 회귀 검사 — 계획 docs/pipeline-v2-infra-plan.md §7.
# 1~9는 PR-3b(AMI 파이프라인), 10~14는 PR-3c(워커 풀·SG·롤·알람·앱 롤).
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
#  10. 워커 인스턴스: AZ 맵 for_each, ami = var.gpu_ami_id, IMDSv2 hop 2, key_name 없음, user_data 없음, Name 태그 = local.name(§7-1·6)
#  11. aws_ec2_instance_state stopped + ignore_changes = [state](§7-2)
#  12. GPU SG(security 모듈): 인그레스 규칙 0개, RDS SG에 rds_from_score_gpu(§7-3)
#  13. 워커 롤: S3 previews/* 만, SSM은 세 파라미터 ARN(와일드카드 없음), lambda: 액션 없음, StopInstances 태그 조건(§7-4).
#      앱 롤(compute): Start/Stop 태그 조건, DescribeInstances만 `*`(§7-5)
#  14. 유휴 정지 알람: InstanceId dimension, notBreaching, period 300 × 6, 인스턴스와 같은 for_each, 정지 액션은 이 모듈 안에만(§7-9·10)

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
workers="$mod/workers.tf"
security_main="$repo_root/modules/security/main.tf"
compute_main="$repo_root/modules/compute/main.tf"

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


# --- 10. 워커 인스턴스 ---
rg -Fq 'resource "aws_instance" "this"' "$workers"
rg -Fq 'for_each = var.worker_subnet_ids' "$workers"
rg -Fq 'ami                         = var.gpu_ami_id' "$workers"
rg -Fq 'http_put_response_hop_limit = 2' "$workers"
rg -n -A40 'resource "aws_instance" "this"' "$workers" | rg -Fq 'http_tokens                 = "required"'
rg -n -A40 'resource "aws_instance" "this"' "$workers" | rg -Fq 'Name = local.name'
if rg -n '^\s*key_name\s*=|^\s*user_data\s*=|^\s*data "aws_ami"|^\s*most_recent\s*=' "$workers"; then
  echo "워커 인스턴스에 key_name·user_data·most_recent AMI가 있다 — SSM만, 유닛은 AMI에, AMI는 변수로" >&2
  exit 1
fi
rg -Fq 'default     = "g6.xlarge"' "$mod_vars"

# --- 11. 생성 직후 정지 ---
rg -Fq 'resource "aws_ec2_instance_state" "stopped"' "$workers"
rg -Fq 'state       = "stopped"' "$workers"
rg -n -A8 'resource "aws_ec2_instance_state" "stopped"' "$workers" | rg -Fq 'ignore_changes = [state]'

# --- 12. GPU SG ---
rg -Fq 'resource "aws_security_group" "score_gpu"' "$security_main"
rg -Fq 'resource "aws_vpc_security_group_ingress_rule" "rds_from_score_gpu"' "$security_main"
rg -n -A6 '"rds_from_score_gpu"' "$security_main" | rg -Fq 'referenced_security_group_id = aws_security_group.score_gpu.id'
if rg -B1 -A6 'aws_vpc_security_group_ingress_rule' "$security_main" | rg -q '^\s*security_group_id\s*=\s*aws_security_group\.score_gpu\.id'; then
  echo "GPU SG에 인그레스 규칙이 있다 — 인바운드 0, 접속은 SSM만" >&2
  exit 1
fi

# --- 13. 워커 롤 · 앱 롤 ---
rg -Fq 'resources = ["${var.photo_bucket_arn}/previews/*"]' "$workers"
rg -Fq '${local.ssm_parameter_arn_prefix}/spring.datasource.url' "$workers"
rg -Fq '${local.ssm_parameter_arn_prefix}/photoselect.db.password' "$workers"
rg -Fq '${local.ssm_parameter_arn_prefix}/app.storage.bucket' "$workers"
if rg -n 'ssm_parameter_arn_prefix}/?\*|parameter_prefix}/?\*|"lambda:' "$workers"; then
  echo "워커 롤에 SSM 프리픽스 와일드카드나 lambda: 액션이 있다(결정 J, 벤치마크 권한 금지)" >&2
  exit 1
fi
rg -n -A10 'sid       = "StopSelf"' "$workers" | rg -Fq 'variable = "ec2:ResourceTag/Name"'
rg -n -A10 'sid       = "StopSelf"' "$workers" | rg -Fq 'values   = [local.name]'
rg -Fq 'policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"' "$workers"
rg -n -A12 'sid = "StartStopScoreGpuWorkers"' "$compute_main" | rg -Fq 'variable = "ec2:ResourceTag/Name"'
rg -n -A12 'sid = "StartStopScoreGpuWorkers"' "$compute_main" | rg -Fq '"ec2:StartInstances",'
rg -n -A12 'sid = "StartStopScoreGpuWorkers"' "$compute_main" | rg -Fq '"ec2:StopInstances",'
rg -n -A4 'sid       = "DescribeScoreGpuWorkers"' "$compute_main" | rg -Fq 'resources = ["*"]'
if rg -n -A12 'sid = "StartStopScoreGpuWorkers"' "$compute_main" | rg -q 'resources = \["\*"\]'; then
  echo "앱 롤 Start/Stop 리소스가 *다 — 인스턴스 ARN + 태그 조건이어야 한다" >&2
  exit 1
fi
rg -Fq 'score_gpu_tag_name = "wes-score-gpu"' "$root_main"

# --- 14. 유휴 정지 알람 ---
rg -Fq 'resource "aws_cloudwatch_metric_alarm" "idle_stop"' "$workers"
rg -n -A30 'resource "aws_cloudwatch_metric_alarm" "idle_stop"' "$workers" | rg -Fq 'for_each = aws_instance.this'
rg -Fq 'InstanceId = each.value.id' "$workers"
rg -Fq 'treat_missing_data  = "notBreaching"' "$workers"
rg -Fq 'period              = 300' "$workers"
rg -Fq 'evaluation_periods  = 6' "$workers"
rg -Fq 'alarm_actions = ["arn:aws:automate:${data.aws_region.current.name}:ec2:stop"]' "$workers"
rg -Fq 'depends_on = [aws_iam_service_linked_role.cloudwatch_events]' "$workers"

echo "score-gpu static checks passed"
