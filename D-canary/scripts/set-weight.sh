#!/usr/bin/env bash
set -euo pipefail
ns=${NS:-boutique}
case "${1:-}" in
  90-10) patch=vs-weight-90-10.jsonpatch.json ;;
  50-50) patch=vs-weight-50-50.jsonpatch.json ;;
  0-100) patch=vs-weight-0-100.jsonpatch.json ;;
  *) echo "usage: $0 {90-10|50-50|0-100}"; exit 1 ;;
esac
kubectl -n "$ns" patch virtualservice boutique-vs --type=json \
  --patch-file "D-canary/patches/$patch"
echo "[OK] weight set: $1"

