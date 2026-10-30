#!/usr/bin/env bash
# Deliberately exclude Secret objects, container env, and raw application logs.
set -Eeuo pipefail
: "${NAMESPACE:?}" "${RELEASE_NAME:?}" "${DIAGNOSTICS_DIR:?}"
mkdir -p "$DIAGNOSTICS_DIR"
kubectl --request-timeout=15s -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance=$RELEASE_NAME"   -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,WAITING:.status.containerStatuses[*].state.waiting.reason' > "$DIAGNOSTICS_DIR/pods.txt" 2>&1 || true
kubectl --request-timeout=15s -n "$NAMESPACE" get deployment "$RELEASE_NAME"   -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,AVAILABLE:.status.availableReplicas,UPDATED:.status.updatedReplicas,REASON:.status.conditions[*].reason' > "$DIAGNOSTICS_DIR/deployment.txt" 2>&1 || true
helm history "$RELEASE_NAME" -n "$NAMESPACE" -o json | python3 -c 'import json,sys; print(json.dumps([{k:r.get(k) for k in ("revision","status","chart","app_version")} for r in json.load(sys.stdin)],indent=2))' > "$DIAGNOSTICS_DIR/helm-history.json" 2>/dev/null || true
