#!/usr/bin/env bash
set -Eeuo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/common.sh
source "$script_dir/common.sh"
: "${NAMESPACE:?}" "${RELEASE_NAME:?}"
work=$(mktemp -d)
pf_pid=''
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  if [[ -n "$pf_pid" ]]; then kill "$pf_pid" 2>/dev/null || true; wait "$pf_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT
url=${SMOKE_URL:-}
if [[ -z "$url" ]]; then
  service_port=${SERVICE_PORT:-8080}
  [[ "$service_port" =~ ^[0-9]+$ ]] || die 'Invalid SERVICE_PORT'
  kubectl -n "$NAMESPACE" port-forward --address=127.0.0.1 "service/$RELEASE_NAME" ":$service_port" > "$work/port-forward.log" 2>&1 &
  pf_pid=$!
  port=''
  for ((attempt=0; attempt<30; attempt++)); do
    port=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) ->.*/\1/p' "$work/port-forward.log" | head -n 1)
    [[ -z "$port" ]] || break
    kill -0 "$pf_pid" 2>/dev/null || die 'Port-forward process exited'
    sleep 1
  done
  [[ "$port" =~ ^[0-9]+$ ]] || die 'Port-forward did not become ready'
  url="http://127.0.0.1:$port${SMOKE_PATH:-/actuator/health/readiness}"
fi
[[ "$url" == http://* || "$url" == https://* ]] || die 'SMOKE_URL must use HTTP(S)'
attempts=${SMOKE_ATTEMPTS:-20}
retry_seconds=${SMOKE_RETRY_SECONDS:-3}
[[ "$attempts" =~ ^[1-9][0-9]*$ && "$retry_seconds" =~ ^[0-9]+$ ]] || die 'Invalid smoke retry configuration'
for ((attempt=0; attempt<attempts; attempt++)); do
  code=$(curl --silent --show-error --max-time 5 --output "$work/body" --write-out '%{http_code}' "$url" 2>/dev/null) || code=000
  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    if python3 - "$work/body" "${SMOKE_EXPECTED_STATUS:-UP}" <<'PYTHON'
import json,pathlib,sys
expected=sys.argv[2]
if not expected: raise SystemExit(0)
try: body=json.loads(pathlib.Path(sys.argv[1]).read_text())
except (ValueError,OSError): raise SystemExit(1)
raise SystemExit(0 if isinstance(body,dict) and body.get('status')==expected else 1)
PYTHON
    then
      if [[ -n "${SMOKE_BUSINESS_URL:-}" ]]; then
        business_code=$(curl --silent --show-error --max-time 10 --output /dev/null --write-out '%{http_code}' "$SMOKE_BUSINESS_URL") || die 'Business smoke request failed'
        [[ "$business_code" =~ ^2[0-9][0-9]$ ]] || die 'Business smoke endpoint did not return 2xx'
      fi
      log 'Smoke test passed'
      exit 0
    fi
  fi
  sleep "$retry_seconds"
done
die 'Smoke test failed; response body is deliberately excluded from logs'
