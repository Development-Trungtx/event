#!/usr/bin/env bash
# Shared by deployment scripts. Never enable set -x around credentials.
set -Eeuo pipefail
log() { printf '[cicd] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
require_env() { [[ -n "${!1:-}" ]] || die "Required environment variable: $1"; }
validate_target() {
  for name in NAMESPACE RELEASE_NAME EXPECTED_KUBE_CONTEXT; do require_env "$name"; done
  [[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#NAMESPACE} -le 63 ]] || die 'Invalid NAMESPACE'
  [[ "$RELEASE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#RELEASE_NAME} -le 53 ]] || die 'Invalid RELEASE_NAME'
  for tool in kubectl helm python3 curl; do need "$tool"; done
  [[ "$(helm version --template '{{.Version}}')" == v3.* ]] || die 'Use the pinned Helm 3 version; do not silently switch to Helm 4'
  local actual
  actual=$(kubectl config current-context)
  [[ "$actual" == "$EXPECTED_KUBE_CONTEXT" ]] || die 'Kubernetes context differs from EXPECTED_KUBE_CONTEXT'
  kubectl --request-timeout=15s -n "$NAMESPACE" get serviceaccounts >/dev/null
  [[ "$(kubectl -n "$NAMESPACE" auth can-i patch deployments.apps)" == yes ]] || die 'No deployment patch permission'
  [[ "$(kubectl -n "$NAMESPACE" auth can-i create secrets)" == yes ]] || die 'No Helm release storage permission'
}
write_summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
}
