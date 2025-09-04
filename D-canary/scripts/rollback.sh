#!/usr/bin/env bash
set -euo pipefail
ns=${NS:-boutique}
# v1으로 즉시 복귀
kubectl -n "$ns" patch virtualservice boutique-vs --type=json \
  -p '[{"op":"replace","path":"/spec/http/0/route/0/weight","value":100},
       {"op":"replace","path":"/spec/http/0/route/1/weight","value":0}]'
# 필요하면 카나리 인스턴스 축소
kubectl -n "$ns" scale deploy/frontend-v2 --replicas=0 || true
echo "[OK] rolled back to v1"

