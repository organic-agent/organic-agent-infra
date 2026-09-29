#!/usr/bin/env bash
# 상시 서버 인스턴스의 AMI 고정(#69) 정적 검사.
#
# 네 모듈은 AMI를 data "aws_ami" most_recent로 고른다. Canonical이 새 이미지를 내면 값이 바뀌므로,
# ignore_changes = [ami]가 없으면 코드 변경 없이도 다음 apply가 서버를 교체한다(2026-09-29 앱 서버 교체 사고).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

for module in compute monitoring admin-access frontend-test; do
  main="$repo_root/modules/$module/main.tf"
  if rg -Fq 'most_recent = true' "$main" && ! rg -q 'ignore_changes\s*=\s*\[[^]]*\bami\b' "$main"; then
    echo "modules/$module: instance picks the most recent AMI but does not ignore ami changes" >&2
    exit 1
  fi
done

echo "server AMI pin static checks passed"
