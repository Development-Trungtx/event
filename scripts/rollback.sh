#!/usr/bin/env bash
set -Eeuo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/common.sh
source "$script_dir/common.sh"
validate_target
revision=${1:?Usage: rollback.sh REVISION}
[[ "$revision" =~ ^[1-9][0-9]*$ ]] || die 'Revision must be a positive integer'
history=$(helm history "$RELEASE_NAME" -n "$NAMESPACE" --max 100 -o json)
python3 - "$revision" "$history" <<'PYTHON'
import json,sys
matches=[r for r in json.loads(sys.argv[2]) if str(r['revision'])==sys.argv[1] and r['status'] in ('deployed','superseded')]
if len(matches)!=1: raise SystemExit('Revision is not an available successful Helm revision')
PYTHON
helm rollback "$RELEASE_NAME" "$revision" -n "$NAMESPACE" --wait --wait-for-jobs --timeout "${DEPLOY_TIMEOUT:-10m}"
bash "$script_dir/smoke-test.sh"
write_summary "Manual rollback: **SUCCESS**; restored revision $revision for $RELEASE_NAME in $NAMESPACE."
