#!/usr/bin/env bash
set -euo pipefail
kubectl apply -f D-canary/01-frontend-v2.yaml
kubectl apply -f D-canary/10-destinationrule-frontend.yaml
kubectl apply -f D-canary/20-virtualservice-canary.yaml
echo "[OK] base canary applied (v1=100, v2=0)"

