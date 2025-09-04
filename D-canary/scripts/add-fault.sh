#!/usr/bin/env bash
set -euo pipefail
ns=${NS:-boutique}
kubectl -n "$ns" patch virtualservice boutique-vs --type=json \
  --patch-file D-canary/patches/vs-add-fault-500-50.jsonpatch.json
echo "[OK] fault injected (500 @ 50%)"

