#!/usr/bin/env bash
set -Eeuo pipefail
# SSM ENV_VAR interpolation is mandatory; do not fall back to inline substitution.
: "${SSM_ArtifactKey:?}" "${SSM_ArtifactSha256:?}" "${SSM_Revision:?}"
[[ "$SSM_Revision" =~ ^[a-f0-9]{40}$ ]]
[[ "$SSM_ArtifactSha256" =~ ^[a-f0-9]{64}$ ]]
[[ "$SSM_ArtifactKey" == "releases/$SSM_Revision.tar.gz" ]]

verify_runtime() {
python3 - "$1" <<'PY_RUNTIME'
import json
import subprocess
import sys
import urllib.request

revision = sys.argv[1]
def docker_json(*args):
    return json.loads(subprocess.check_output(['docker', *args], text=True))
container = docker_json('inspect', 'wes-frontend')[0]
image = docker_json('image', 'inspect', f'wes-frontend:{revision}')[0]
config, host = container['Config'], container['HostConfig']
assert container['State']['Running'], 'Frontend container is not running'
assert config['Image'] == f'wes-frontend:{revision}'
assert container['Image'] == image['Id'], 'Running image differs from release image'
assert config['User'].split(':')[0] not in ('', '0', 'root'), 'Root user is forbidden'
uid = subprocess.check_output(['docker', 'exec', 'wes-frontend', 'id', '-u'], text=True).strip()
assert uid == '1001', 'Frontend process must use UID 1001'
assert host['ReadonlyRootfs'] is True
assert 'ALL' in host['CapDrop']
assert any(option.split(':')[0] == 'no-new-privileges' for option in host['SecurityOpt'])
assert host['Privileged'] is False
assert host['Memory'] == 768 * 1024 * 1024
assert host['PidsLimit'] == 256
assert host['PortBindings'] == {'3000/tcp': [{'HostIp': '127.0.0.1', 'HostPort': '3000'}]}
with urllib.request.urlopen('http://127.0.0.1:3000/health', timeout=10) as response:
    assert response.status == 200
with urllib.request.urlopen('http://127.0.0.1:3000/version.json', timeout=10) as response:
    version = json.load(response)
assert version.get('revision') == revision, 'Live revision differs from source commit'
assert version.get('service') == 'wes-frontend-test', 'Unexpected frontend service'
print(json.dumps({
    'revision': revision,
    'imageId': image['Id'],
    'user': config['User'],
    'uid': uid,
    'readOnlyRootfs': host['ReadonlyRootfs'],
    'capDrop': host['CapDrop'],
    'securityOpt': host['SecurityOpt'],
    'memoryBytes': host['Memory'],
    'pidsLimit': host['PidsLimit'],
    'portBindings': host['PortBindings'],
    'health': 'UP',
}))
PY_RUNTIME
}

# A canceled Actions run does not cancel its SSM command. Serialize whole wrappers.
exec 8>/var/lock/wes-frontend-actions-deploy.lock
flock -n 8 || { echo 'Another Actions frontend deployment is still running.' >&2; exit 1; }

previous=$(docker inspect --format '{{.Config.Image}}' wes-frontend 2>/dev/null || true)
previous_id=''
previous_previous_image=''
expected_new_image_id=''
if [[ -n "$previous" ]]; then
  [[ "$previous" =~ ^wes-frontend:[a-f0-9]{40}$ ]]
  # Never replace an existing unhealthy/unsafe runtime during this release.
  verify_runtime "${previous#wes-frontend:}" >/dev/null
  previous_id=$(docker inspect --format '{{.Image}}' wes-frontend)
  previous_previous_image=$(cat /opt/wes-frontend/previous-image 2>/dev/null || true)
fi

restore_previous() {
  local result=$?
  trap - ERR
  set +e
  if [[ -z "$previous_id" ]]; then
    echo 'Deployment failed; no verified prior frontend exists to restore.' >&2
    exit "$result"
  fi
  # A manual deployment uses the host helper lock. Never roll back over it.
  exec 9>/var/lock/wes-frontend-deploy.lock
  if ! flock -n 9; then
    echo 'Deployment failed; another host deployment is active, so rollback was not attempted.' >&2
    exit "$result"
  fi
  local current_id
  current_id=$(docker inspect --format '{{.Image}}' wes-frontend 2>/dev/null || true)
  if [[ -z "$expected_new_image_id" ]]; then
    expected_new_image_id=$(docker image inspect "wes-frontend:$SSM_Revision" --format '{{.Id}}' 2>/dev/null || true)
  fi
  if [[ -n "$current_id" && "$current_id" != "$previous_id" && "$current_id" != "$expected_new_image_id" ]]; then
    echo 'Deployment failed; a different release is running, so rollback was not attempted.' >&2
    exit "$result"
  fi
  # The host helper may already have restored the prior image. Keep it if verified.
  if [[ "$(docker inspect --format '{{.Image}}' wes-frontend 2>/dev/null)" == "$previous_id" ]] && verify_runtime "${previous#wes-frontend:}" >/dev/null 2>&1; then
    echo 'Deployment failed; verified prior frontend is already running.' >&2
    exit "$result"
  fi
  echo 'Deployment failed; restoring the previously verified frontend image.' >&2
  docker rm -f wes-frontend-candidate >/dev/null 2>&1 || true
  docker rm -f wes-frontend >/dev/null 2>&1 || true
  # Preserve the exact previous image even when retrying the same commit tag.
  if ! docker image tag "$previous_id" "$previous"; then
    echo 'Rollback failed: previous image tag could not be restored.' >&2
    exit "$result"
  fi
  if ! docker run -d --name wes-frontend --restart unless-stopped --init --read-only --cap-drop ALL \
    --security-opt no-new-privileges --memory 768m --pids-limit 256 \
    --tmpfs /tmp:rw,nosuid,nodev,size=128m --tmpfs /app/.next/cache:rw,nosuid,nodev,size=128m \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
    -e NODE_ENV=production -e PORT=3000 -e HOSTNAME=0.0.0.0 \
    -e "SOURCE_REVISION=${previous#wes-frontend:}" -e "BUILD_SHA=${previous#wes-frontend:}" \
    -p 127.0.0.1:3000:3000 "$previous"; then
    echo 'Rollback failed: previous frontend could not start.' >&2
    exit "$result"
  fi
  for attempt in $(seq 1 30); do
    if verify_runtime "${previous#wes-frontend:}" >/dev/null 2>&1; then
      printf '%s\n' "${previous#wes-frontend:}" >/opt/wes-frontend/current-revision
      printf '%s\n' "$previous_previous_image" >/opt/wes-frontend/previous-image
      echo 'Previously verified frontend restored and checked.' >&2
      exit "$result"
    fi
    sleep 2
  done
  echo 'Rollback failed: restored frontend did not pass runtime checks.' >&2
  exit "$result"
}
trap restore_previous ERR
/usr/local/bin/deploy-frontend "$SSM_ArtifactKey" "$SSM_ArtifactSha256" "$SSM_Revision"
expected_new_image_id=$(docker image inspect "wes-frontend:$SSM_Revision" --format '{{.Id}}')
verify_runtime "$SSM_Revision"
trap - ERR
