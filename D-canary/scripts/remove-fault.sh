#!/usr/bin/env bash
set -euo pipefail
ns=${NS:-boutique}
kubectl -n "$ns" patch virtualservice boutique-vs --type=json \
  --patch-file D-canary/patches/vs-remove-fault.jsonpatch.json || true
echo "[OK] fault removed (if existed)"

