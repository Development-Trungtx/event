#!/usr/bin/env bash
set -Eeuo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/common.sh
source "$script_dir/common.sh"
validate_target
: "${BUNDLE_DIR:?}" "${DIAGNOSTICS_DIR:?}"
metadata_text=$(python3 - "$BUNDLE_DIR/release.json" <<'PYTHON'
import json,re,sys
m=json.load(open(sys.argv[1]))
assert re.fullmatch(r'ghcr.io/[a-z0-9._/-]+',m['image_repository'])
assert re.fullmatch(r'sha256:[0-9a-f]{64}',m['image_digest'])
assert m['image_digest']!='sha256:'+'0'*64
assert re.fullmatch(r'[0-9a-f]{40}',m['source_sha'])
assert m['source_ref'] in ('refs/heads/dev','refs/heads/master')
print(m['image_repository']);print(m['image_digest']);print(m['source_sha']);print(m['source_ref'])
PYTHON
)
mapfile -t metadata <<< "$metadata_text"
[[ ${#metadata[@]} == 4 ]] || die 'Invalid release metadata'
image_repository=${metadata[0]};image_digest=${metadata[1]};source_sha=${metadata[2]};source_ref=${metadata[3]}
case "${TARGET_ENVIRONMENT:?}:$source_ref" in
  dev:refs/heads/dev) values='values-dev.yaml' ;;
  production:refs/heads/master) values='values-prod.yaml' ;;
  *) die 'Source ref/environment mismatch' ;;
esac
chart="$BUNDLE_DIR/chart"
[[ -f "$chart/Chart.yaml" && -f "$chart/$values" ]] || die 'Missing chart or environment values'
# A failed API request must not be interpreted as a first installation.
releases=$(helm list -n "$NAMESPACE" --all --filter "^$RELEASE_NAME$" -o json)
state=$(python3 -c 'import json,sys; a=json.load(sys.stdin); print(a[0]["status"] if a else "absent")' <<< "$releases")
[[ "$state" != pending-* && "$state" != uninstalling ]] || die 'Release is busy; inspect it before retrying'
previous=0
if [[ "$state" != absent ]]; then
  history=$(helm history "$RELEASE_NAME" -n "$NAMESPACE" --max 100 -o json)
  previous=$(python3 -c 'import json,sys; a=[int(r["revision"]) for r in json.load(sys.stdin) if r["status"] in ("deployed","superseded")]; print(max(a,default=0))' <<< "$history")
fi
write_summary "### Deployment: $RELEASE_NAME / $NAMESPACE" "Source: $source_sha" "Image: $image_repository@$image_digest" "Previous successful Helm revision: $previous"
log "Deploying $RELEASE_NAME in $NAMESPACE"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local/local}/actions/runs/${GITHUB_RUN_ID:-0}"
if helm upgrade --install "$RELEASE_NAME" "$chart" -n "$NAMESPACE"   -f "$chart/values.yaml" -f "$chart/$values"   --set-string "image.repository=$image_repository" --set-string "image.digest=$image_digest"   --set-string "releaseMetadata.sourceSha=$source_sha" --set-string "releaseMetadata.runUrl=$run_url"   --wait --wait-for-jobs --timeout "${DEPLOY_TIMEOUT:-10m}" --history-max 10; then
  if bash "$script_dir/smoke-test.sh"; then
    revision=$(helm status "$RELEASE_NAME" -n "$NAMESPACE" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
    write_summary "Result: **SUCCESS**, Helm revision $revision"
    exit 0
  fi
fi
log 'Deployment failed; collecting limited diagnostics before recovery'
bash "$script_dir/collect-diagnostics.sh" || true
if (( previous > 0 )); then
  if helm rollback "$RELEASE_NAME" "$previous" -n "$NAMESPACE" --wait --wait-for-jobs --timeout "${DEPLOY_TIMEOUT:-10m}" && bash "$script_dir/smoke-test.sh"; then
    write_summary "Result: **FAILED**, previous revision $previous restored and smoke test passed."
  else
    write_summary 'Result: **FAILED**, automatic recovery also failed; manual intervention required.'
  fi
else
  # Do not uninstall a first installation automatically: preserve evidence and avoid deleting data.
  write_summary 'Result: **FAILED**, first installation has no prior successful revision; resources preserved for inspection.'
fi
exit 1
