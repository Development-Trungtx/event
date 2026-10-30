#!/usr/bin/env bash
set -Eeuo pipefail
: "${KUBE_CONFIG_B64:?Configure environment secret KUBE_CONFIG_B64}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
umask 077
config=$(mktemp "$RUNNER_TEMP/kubeconfig.XXXXXXXX")
if ! printf '%s' "$KUBE_CONFIG_B64" | base64 --decode > "$config"; then
  rm -f "$config"
  echo 'KUBE_CONFIG_B64 is not valid base64.' >&2
  exit 1
fi
[[ -s "$config" ]] || { rm -f "$config"; exit 1; }
printf 'KUBECONFIG=%s\n' "$config" >> "$GITHUB_ENV"
