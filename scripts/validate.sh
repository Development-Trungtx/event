#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
for script in scripts/*.sh; do bash -n "$script"; done
shellcheck -x scripts/*.sh
actionlint -config-file .github/actionlint.yaml .github/workflows/*.yml
for environment in dev prod; do
  helm lint helm/order-service --strict -f "helm/order-service/values-$environment.yaml"
  helm template "order-service-$environment" helm/order-service -f "helm/order-service/values-$environment.yaml" >/dev/null
done
# Regression tests exercise deployment failure handling without a real cluster.
python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
