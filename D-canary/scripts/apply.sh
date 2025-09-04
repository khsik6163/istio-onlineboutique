#!/usr/bin/env bash
set -euo pipefail

# 스크립트 기준으로 D-canary 디렉토리 절대경로 계산
CANARY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-boutique}"

echo "[canary] namespace=${NS}"
echo "[canary] dir=${CANARY_DIR}"

# 1) v2 배포 (라벨/셀렉터가 subset=v2로 매칭되도록 가정)
kubectl -n "${NS}" apply -f "${CANARY_DIR}/01-frontend-v2.yaml"

# 2) DestinationRule (subset: v1, v2 정의)
kubectl -n "${NS}" apply -f "${CANARY_DIR}/10-destinationrule-frontend.yaml"

# 3) VirtualService (가중치 라우팅)
kubectl -n "${NS}" apply -f "${CANARY_DIR}/20-virtualservice-canary.yaml"

echo "[canary] waiting rollout..."
kubectl -n "${NS}" rollout status deploy/frontend --timeout=120s

echo "[canary] current VS:"
kubectl -n "${NS}" get vs -o wide

echo "[canary] current DR:"
kubectl -n "${NS}" get dr -o wide

echo "[canary] done."

