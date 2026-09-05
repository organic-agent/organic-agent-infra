#!/usr/bin/env bash
set -Eeuo pipefail
# Run with an authenticated deployment operator. No long-lived keys are created.
[[ $# == 1 ]] || { echo 'usage: scripts/deploy-frontend-test.sh FRONTEND_CHECKOUT' >&2; exit 2; }
frontend=$(cd "$1" && pwd)
infra=$(cd "$(dirname "$0")/.." && pwd)
[[ -z "$(git -C "$frontend" status --porcelain)" ]] || { echo 'Commit frontend sources before deployment.' >&2; exit 2; }
revision=$(git -C "$frontend" rev-parse HEAD)
[[ "$revision" =~ ^[a-f0-9]{40}$ ]] || exit 2
bucket=$(terraform -chdir="$infra" output -raw frontend_test_artifact_bucket)
instance=$(terraform -chdir="$infra" output -raw frontend_test_instance_id)
region=ap-northeast-2
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
git -C "$frontend" archive --format=tar HEAD | gzip >"$scratch/source.tar.gz"
python3 - "$scratch/source.tar.gz" <<'PY'
import pathlib, sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    for member in archive.getmembers():
        path = pathlib.PurePosixPath(member.name)
        blocked = any(p in {'.git', 'node_modules', '.next', '.npmrc'} or (p.startswith('.env') and not p.endswith('.example')) for p in path.parts)
        if blocked or path.is_absolute() or '..' in path.parts or member.issym() or member.islnk():
            raise SystemExit('Unsafe or secret-bearing source artifact member: '+member.name)
PY
archive_sha=$(shasum -a 256 "$scratch/source.tar.gz" | cut -d ' ' -f 1)
key="releases/$revision.tar.gz"
aws s3 cp "$scratch/source.tar.gz" "s3://$bucket/$key" --region "$region" --sse AES256 --only-show-errors
python3 - "$key" "$archive_sha" "$revision" >"$scratch/parameters.json" <<'PY'
import json, shlex, sys
print(json.dumps({'commands':[' '.join(shlex.quote(a) for a in ['/usr/local/bin/deploy-frontend',*sys.argv[1:]])], 'executionTimeout':['1800']}))
PY
command_id=$(aws ssm send-command --region "$region" --instance-ids "$instance" --document-name AWS-RunShellScript --comment "Deploy frontend revision $revision" --parameters "file://$scratch/parameters.json" --query Command.CommandId --output text)
printf 'SSM command: %s\nSource revision: %s\n' "$command_id" "$revision"
for attempt in $(seq 1 180); do
  sleep 10
  status=$(aws ssm get-command-invocation --region "$region" --instance-id "$instance" --command-id "$command_id" --query Status --output text)
  case "$status" in
    Success) break ;;
    Pending|InProgress|Delayed) continue ;;
    *) aws ssm get-command-invocation --region "$region" --instance-id "$instance" --command-id "$command_id" --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}'; exit 1 ;;
  esac
done
[[ "$status" == Success ]] || { echo 'Deployment timeout; inspect the SSM command.' >&2; exit 1; }
curl --retry 5 --retry-delay 2 -fsS https://test.easyselect.kr/health
curl -fsS https://test.easyselect.kr/version.json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert sys.argv[1] in d.values(),d; print(json.dumps(d))' "$revision"
