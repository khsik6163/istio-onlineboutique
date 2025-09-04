#!/usr/bin/env bash
set -euo pipefail
ns=${NS:-boutique}
igw=$(kubectl -n istio-system get pod -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}')
echo "== Routes (weights) =="
istioctl -n istio-system proxy-config routes "$igw" | grep -E '^name: |/ \*|/api/\*|subset|weight' -n || true
echo
echo "== VS (raw) =="
kubectl -n "$ns" get vs boutique-vs -o yaml | sed -n '1,200p'

