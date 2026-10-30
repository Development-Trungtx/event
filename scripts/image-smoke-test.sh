#!/usr/bin/env bash
# java mode checks the image runtime. http mode starts Spring with a CI profile/dependencies.
set -Eeuo pipefail
image=${1:?Usage: image-smoke-test.sh IMAGE}
mode=${IMAGE_SMOKE_MODE:-java}
if [[ "$mode" == java ]]; then
  docker run --rm --network none --read-only --tmpfs "/tmp:rw,nosuid,size=128m" --cap-drop ALL --security-opt no-new-privileges "$image" java -version
  echo 'Runtime check passed. Spring HTTP startup is checked after deployment; set IMAGE_SMOKE_MODE=http for CI startup testing.'
  exit 0
fi
[[ "$mode" == http ]] || { echo 'IMAGE_SMOKE_MODE must be java or http' >&2; exit 1; }
args=(--detach --read-only --tmpfs "/tmp:rw,nosuid,size=128m" --cap-drop ALL --security-opt no-new-privileges --publish 127.0.0.1::8080
  --env SERVER_PORT=8080 --env MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED=true)
if [[ -n "${IMAGE_SMOKE_ENV_FILE:-}" ]]; then
  [[ -f "$IMAGE_SMOKE_ENV_FILE" ]] || { echo 'Missing IMAGE_SMOKE_ENV_FILE' >&2; exit 1; }
  args+=(--env-file "$IMAGE_SMOKE_ENV_FILE")
fi
container=$(docker run "${args[@]}" "$image")
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
port=$(docker port "$container" 8080/tcp | sed -n 's/^127.0.0.1://p')
[[ "$port" =~ ^[0-9]+$ ]] || exit 1
for ((attempt=0; attempt<60; attempt++)); do
  if curl --silent --fail --max-time 3 "http://127.0.0.1:$port/actuator/health/readiness" | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get("status")=="UP" else 1)' 2>/dev/null; then exit 0; fi
  sleep 3
done
echo 'Spring image startup smoke test failed. Raw container logs are not printed automatically.' >&2
exit 1
