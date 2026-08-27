#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
root_main="$repo_root/main.tf"
storage_main="$repo_root/modules/storage/main.tf"
storage_variables="$repo_root/modules/storage/variables.tf"

rg -Fq 'admin_web_origin   = "https://${local.admin_fqdn}"' "$root_main"
rg -Fq 'web_origins        = distinct(concat(local.public_web_origins, [local.admin_web_origin]))' "$root_main"
rg -Fq 'allowed_origins = var.web_origins' "$storage_main"
rg -Fq 'allowed_methods = ["PUT", "GET", "HEAD"]' "$storage_main"
rg -Fq 'can(regex("^https?://[^/*]+$", o))' "$storage_variables"

if rg -n 'allowed_origins[[:space:]]*=.*\*|https?://[^"[:space:]]*\*' "$root_main" "$storage_main"; then
  echo "S3 CORS origins must not contain wildcards" >&2
  exit 1
fi

if rg -n 'allowed_methods[[:space:]]*=.*(POST|DELETE|PATCH)' "$storage_main"; then
  echo "Admin browser access must be limited to PUT, GET, and HEAD" >&2
  exit 1
fi

echo "Admin S3 CORS static checks passed"
