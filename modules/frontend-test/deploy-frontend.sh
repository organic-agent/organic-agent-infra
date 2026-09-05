#!/usr/bin/env bash
set -Eeuo pipefail
# Args: private S3 release key, archive SHA256, source revision.
[[ $# == 3 ]] || { echo 'usage: deploy-frontend KEY SHA256 REVISION' >&2; exit 2; }
key=$1
archive_sha=$2
revision=$3
[[ "$key" =~ ^releases/[a-zA-Z0-9._-]+\.tar\.gz$ ]] || exit 2
[[ "$archive_sha" =~ ^[a-f0-9]{64}$ && "$revision" =~ ^[a-f0-9]{7,64}$ ]] || exit 2
source /etc/wes-frontend/deployment.env
exec 9>/var/lock/wes-frontend-deploy.lock
flock -n 9 || { echo 'Another frontend deployment is running' >&2; exit 1; }
release=/opt/wes-frontend/releases/$revision
mkdir -p "$release"
archive=$(mktemp /opt/wes-frontend/source.XXXXXX.tar.gz)
trap 'rm -f "$archive"' EXIT
aws s3 cp "s3://$ARTIFACT_BUCKET/$key" "$archive" --region "$AWS_REGION" --only-show-errors
printf '%s  %s\n' "$archive_sha" "$archive" | sha256sum -c -
# Release archives contain only project sources, never credentials or local build output.
python3 - "$archive" "$release" <<'PY'
import pathlib, sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    for member in archive.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or member.issym() or member.islnk():
            raise SystemExit('unsafe archive member')
    archive.extractall(sys.argv[2], filter='data')
PY
docker build --build-arg "BUILD_SHA=$revision" --build-arg "SOURCE_REVISION=$revision" \
  --build-arg NEXT_PUBLIC_API_URL=https://api.easyselect.kr \
  --build-arg NEXT_PUBLIC_API_BASE_URL=https://api.easyselect.kr \
  --build-arg NEXT_PUBLIC_SITE_URL=https://test.easyselect.kr \
  -t "wes-frontend:$revision" "$release"
# Validate candidate while the current application stays online.
docker rm -f wes-frontend-candidate >/dev/null 2>&1 || true
docker run -d --name wes-frontend-candidate --init --read-only --cap-drop ALL \
  --security-opt no-new-privileges --memory 768m --pids-limit 256 \
  --tmpfs /tmp:rw,nosuid,nodev,size=128m --tmpfs /app/.next/cache:rw,nosuid,nodev,size=128m \
  -e NODE_ENV=production -e PORT=3000 -e HOSTNAME=0.0.0.0 \
  -e "SOURCE_REVISION=$revision" -e "BUILD_SHA=$revision" \
  -p 127.0.0.1:3001:3000 "wes-frontend:$revision"
healthy=false
for attempt in $(seq 1 45); do
  if curl -fsS http://127.0.0.1:3001/health >/dev/null; then healthy=true; break; fi
  sleep 2
done
if [[ "$healthy" != true ]]; then
  docker logs --tail 50 wes-frontend-candidate
  docker rm -f wes-frontend-candidate >/dev/null
  exit 1
fi
curl -fsS http://127.0.0.1:3001/version.json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert sys.argv[1] in d.values(), d' "$revision"
docker rm -f wes-frontend-candidate >/dev/null
previous=$(docker inspect wes-frontend --format '{{.Config.Image}}' 2>/dev/null || true)
docker rm -f wes-frontend >/dev/null 2>&1 || true
run_frontend() {
  docker run -d --name wes-frontend --restart unless-stopped --init --read-only --cap-drop ALL \
    --security-opt no-new-privileges --memory 768m --pids-limit 256 \
    --tmpfs /tmp:rw,nosuid,nodev,size=128m --tmpfs /app/.next/cache:rw,nosuid,nodev,size=128m \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
    -e NODE_ENV=production -e PORT=3000 -e HOSTNAME=0.0.0.0 \
    -e "SOURCE_REVISION=${1#wes-frontend:}" -e "BUILD_SHA=${1#wes-frontend:}" \
    -p 127.0.0.1:3000:3000 "$1"
}
run_frontend "wes-frontend:$revision"
for attempt in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:3000/health >/dev/null; then
    printf '%s\n' "$previous" >/opt/wes-frontend/previous-image
    printf '%s\n' "$revision" >/opt/wes-frontend/current-revision
    curl -fsS http://127.0.0.1:3000/version.json
    exit 0
  fi
  sleep 2
done
docker rm -f wes-frontend >/dev/null
[[ -z "$previous" ]] || run_frontend "$previous"
echo 'New release failed health; previous image restored when available' >&2
exit 1
