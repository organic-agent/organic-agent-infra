#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
module_dir="$repo_root/modules/admin-access"

if rg -n 'resource "aws_vpc_security_group_ingress_rule"|ingress[[:space:]]*\{' "$module_dir"; then
  echo "admin-access module must not declare an ingress rule" >&2
  exit 1
fi

rg -q 'route53:ChangeResourceRecordSetsNormalizedRecordNames' "$module_dir/main.tf"
rg -q '_acme-challenge\.\$\{var\.fqdn\}' "$module_dir/main.tf"
rg -q 'values[[:space:]]*=[[:space:]]*\["TXT"\]' "$module_dir/main.tf"
rg -q 'http_put_response_hop_limit[[:space:]]*=[[:space:]]*2' "$module_dir/main.tf"
rg -q 'http_protocol_ipv6[[:space:]]*=[[:space:]]*"disabled"' "$module_dir/main.tf"
rg -q 'tailscale serve --bg --tcp=443 tcp://127\.0\.0\.1:' "$module_dir/templates/user_data.sh.tftpl"
rg -q 'bind 127\.0\.0\.1' "$module_dir/templates/Caddyfile.tftpl"
rg -q 'reverse_proxy \$\{app_host\}:' "$module_dir/templates/Caddyfile.tftpl"
rg -q 'auto_https disable_redirects' "$module_dir/templates/Caddyfile.tftpl"
rg -q '"ip": \["tcp:443"\]' "$repo_root/tailscale/wes-admin-policy.hujson.example"
rg -Fq "ensure_network '\${internal_network_name}'" "$module_dir/templates/runtime_host.sh.tftpl"
rg -Fq "ensure_network '\${runtime_network_name}'" "$module_dir/templates/runtime_host.sh.tftpl"
rg -Fq -- '--internal --subnet' "$module_dir/templates/runtime_host.sh.tftpl"
rg -Fq '169.254.169.254/32' "$module_dir/templates/runtime_host.sh.tftpl"
rg -Fq "touch '\${deploy_lock_path}'" "$module_dir/templates/runtime_host.sh.tftpl"
rg -Fq "flock -w 600 9" "$module_dir/templates/runtime_host.sh.tftpl"
rg -Fq "backoffice_internal_ip = cidrhost(var.internal_network_subnet, 10)" "$module_dir/main.tf"
rg -Fq "/usr/local/bin/caddy validate" "$module_dir/templates/runtime_host.sh.tftpl"
rg -Fq "[ -x /usr/local/bin/caddy ]" "$module_dir/templates/runtime_host.sh.tftpl"
rg -Fq "wes-config.sha256" "$module_dir/templates/runtime_host.sh.tftpl"
rg -Fq "wes-config.sha256" "$module_dir/templates/user_data.sh.tftpl"
rg -Fq '! cmp -s "$caddyfile_tmp" /etc/caddy/Caddyfile' "$module_dir/templates/runtime_host.sh.tftpl"
rg -Fq "systemctl is-active --quiet caddy.service" "$module_dir/templates/runtime_host.sh.tftpl"
rg -Fq "if systemctl restart caddy.service; then" "$module_dir/templates/runtime_host.sh.tftpl"
rg -Fq "service recovery failed" "$module_dir/templates/runtime_host.sh.tftpl"
if rg -Fq "systemctl reload-or-restart caddy.service" "$module_dir/templates/runtime_host.sh.tftpl"; then
  echo "runtime host must restart Caddy because its admin API is disabled" >&2
  exit 1
fi
rg -Fq 'resource "aws_ssm_association" "runtime_host"' "$module_dir/main.tf"
rg -Fq 'runtime_parameter_prefix_arn' "$module_dir/main.tf"
rg -Fq '"s3:GetObject"' "$module_dir/main.tf"
rg -Fq '"s3:PutObject"' "$module_dir/main.tf"
rg -Fq '"s3:DeleteObject"' "$module_dir/main.tf"
rg -Fq '"lambda:InvokeFunction"' "$module_dir/main.tf"

if rg -Fq '"s3:*"' "$module_dir/main.tf" || rg -Fq '"lambda:*"' "$module_dir/main.tf"; then
  echo "admin API runtime policy must not use wildcard S3/Lambda actions" >&2
  exit 1
fi

if rg -n '/wes/prod/admin/tailscale-auth-key' \
  "$module_dir" "$repo_root/admin.tf" "$repo_root/variables.tf" "$repo_root/docs/admin-internal-access.md"; then
  echo "Tailscale auth key must stay outside the app-readable /wes/prod path" >&2
  exit 1
fi

if rg -n 'tailscale funnel|--funnel|tskey-(auth|client)-' \
  "$module_dir" "$repo_root/tailscale" "$repo_root/admin.tf"; then
  echo "Funnel configuration or a literal Tailscale secret was found" >&2
  exit 1
fi

bash -n "$module_dir/templates/user_data.sh.tftpl"
bash -n "$module_dir/templates/runtime_host.sh.tftpl"
echo "admin access static checks passed"
