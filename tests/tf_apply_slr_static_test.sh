#!/usr/bin/env bash
# tf_apply 롤의 서비스 연결 역할(SLR) 권한이 score-gpu가 쓰는 두 ARN으로만 한정돼 있는지 검사한다.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
module_main="$repo_root/modules/github-actions/main.tf"

# 문장과 세 액션이 있고, 리소스는 두 SLR ARN이다.
rg -Fq 'sid = "ServiceLinkedRolesForScoreGpu"' "$module_main"
rg -Fq '"iam:CreateServiceLinkedRole",' "$module_main"
rg -Fq '"iam:DeleteServiceLinkedRole",' "$module_main"
rg -Fq '"iam:GetServiceLinkedRoleDeletionStatus",' "$module_main"
rg -Fq '"arn:aws:iam::${local.account_id}:role/aws-service-role/imagebuilder.amazonaws.com/AWSServiceRoleForImageBuilder",' "$module_main"
rg -Fq '"arn:aws:iam::${local.account_id}:role/aws-service-role/events.amazonaws.com/AWSServiceRoleForCloudWatchEvents",' "$module_main"

# 서비스 연결 역할 경로에 와일드카드가 있으면 아무 SLR이나 만들 수 있게 된다.
if rg -n 'aws-service-role/[^"]*\*' "$module_main"; then
  echo "service-linked role resource is wildcarded" >&2
  exit 1
fi

# SLR 액션이 "*" 리소스 문장(IamRead)에 섞여 들어가지 않았는지 — IamRead는 Get*/List*만 가진다.
if rg -n -A3 'sid       = "IamRead"' "$module_main" | rg -q 'ServiceLinkedRole'; then
  echo "service-linked role actions leaked into the wildcard IamRead statement" >&2
  exit 1
fi

# Image Builder의 PassRole은 ec2.amazonaws.com으로 검사되므로 PassedToService에 imagebuilder를 넣을 이유가 없다.
if rg -Fq 'imagebuilder.amazonaws.com"]' "$module_main"; then
  echo "imagebuilder.amazonaws.com must not be added to iam:PassedToService" >&2
  exit 1
fi

echo "tf_apply service-linked role static checks passed"
