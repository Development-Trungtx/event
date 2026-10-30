#!/usr/bin/env bash
# One-time administrative setup. Never invoke this from the CD workflow.
set -Eeuo pipefail
namespace=${1:?Usage: bootstrap-namespace.sh NAMESPACE}
[[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#namespace} -le 63 ]] || exit 1
kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$namespace" apply -f - <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: github-deployer
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: github-deployer
rules:
  - apiGroups: ['']
    resources: [services, configmaps, secrets, serviceaccounts]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: ['']
    resources: [pods, events]
    verbs: [get, list, watch]
  - apiGroups: ['']
    resources: [pods/portforward]
    verbs: [create]
  - apiGroups: [apps]
    resources: [deployments, replicasets]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [networking.k8s.io]
    resources: [ingresses, networkpolicies]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [policy]
    resources: [poddisruptionbudgets]
    verbs: [get, list, watch, create, update, patch, delete]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: github-deployer
subjects:
  - kind: ServiceAccount
    name: github-deployer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: github-deployer
YAML
printf 'Created namespace-scoped deployment identity in %s. Application secrets and registry access are separate setup steps.\n' "$namespace"
