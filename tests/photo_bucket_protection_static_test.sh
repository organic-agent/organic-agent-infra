#!/usr/bin/env bash
# 운영 사진 버킷이 Terraform 삭제에서 보호되는지(#144) 고정한다.
# 고객 원본 버킷은 force_destroy를 끄고 prevent_destroy를 단다. 로컬·dev 테스트 버킷만 보호를 끈다.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
storage_main="$repo_root/modules/storage/main.tf"
storage_variables="$repo_root/modules/storage/variables.tf"
root_main="$repo_root/main.tf"
dev_main="$repo_root/environments/dev/main.tf"

# 보호용 버킷: force_destroy = false + prevent_destroy = true
protected_block="$(awk '/resource "aws_s3_bucket" "photos_protected"/,/^}/' "$storage_main")"
grep -Fq 'force_destroy = false' <<<"$protected_block"
grep -Fq 'prevent_destroy = true' <<<"$protected_block"

# 기본값은 보호 — 새 환경이 실수로 무방비가 되지 않게
protect_var="$(awk '/variable "protect_from_destroy"/,/^}/' "$storage_variables")"
grep -Fq 'default     = true' <<<"$protect_var"

# 운영 루트의 고객 버킷(module "storage")은 보호를 끄지 않는다
prod_storage_block="$(awk '/^module "storage" \{/,/^}/' "$root_main")"
if grep -Fq 'protect_from_destroy = false' <<<"$prod_storage_block"; then
  echo "운영 사진 버킷(module.storage)은 protect_from_destroy = false 를 쓰면 안 된다" >&2
  exit 1
fi

# 보호를 끄는 곳은 로컬 버킷과 dev 버킷 두 곳뿐이다
off_count="$(cat "$root_main" "$dev_main" | grep -c 'protect_from_destroy = false' || true)"
if [ "$off_count" -ne 2 ]; then
  echo "protect_from_destroy = false 는 storage_local · dev storage 두 곳에만 있어야 한다 (지금 $off_count곳)" >&2
  exit 1
fi
awk '/^module "storage_local" \{/,/^}/' "$root_main" | grep -Fq 'protect_from_destroy = false'
awk '/^module "storage" \{/,/^}/' "$dev_main" | grep -Fq 'protect_from_destroy = false'

# 버킷 리소스가 교체되지 않게 주소를 잇는다
grep -Fq 'to   = module.storage.aws_s3_bucket.photos_protected[0]' "$root_main"

echo "Photo bucket protection static checks passed"
