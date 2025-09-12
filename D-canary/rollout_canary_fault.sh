#!/usr/bin/env bash
set -euo pipefail

NS="boutique"
VS="boutique-vs"
HOST="shop.local"
PORT="8443"
ADDR="127.0.0.1"
VERIFY_HITS=200
CONC=20
PHASE_SEC=20
PROPAGATION_SEC=2

get_canary_idx () {
  kubectl -n "${NS}" get vs "${VS}" -o json \
  | jq -r '.spec.http|to_entries[]|select(.value.name=="canary-route")|.key'
}

patch_weight () {
  local w1="$1" ; local w2="$2"
  local IDX; IDX=$(get_canary_idx)
  if [[ -z "${IDX}" ]]; then
    echo "[ERROR] 'canary-route' 라우트를 찾지 못했습니다. VS 구조를 확인하세요." >&2
    kubectl -n "${NS}" get vs "${VS}" -o yaml | sed -n '1,120p'
    exit 1
  fi
  echo
  echo ">> Patching weights: v1=${w1} / v2=${w2} (http[${IDX}])"
  kubectl -n "${NS}" patch vs "${VS}" --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/http/${IDX}/route/0/weight\",\"value\":${w1}},
    {\"op\":\"replace\",\"path\":\"/spec/http/${IDX}/route/1/weight\",\"value\":${w2}}
  ]" >/dev/null
  echo "   ...applied. waiting ${PROPAGATION_SEC}s for propagation"
  sleep "${PROPAGATION_SEC}"
}

print_dist () {
  echo ">> Sampling x-version distribution (${VERIFY_HITS} hits, P=${CONC})"
  seq "${VERIFY_HITS}" | xargs -I{} -P"${CONC}" \
    curl -sk -D - --resolve "${HOST}:${PORT}:${ADDR}" "https://${HOST}:${PORT}/" -o /dev/null \
  | tr -d '\r' \
  | awk 'BEGIN{IGNORECASE=1} /^x-version:/{print}' \
  | sort | uniq -c
}

phase_load () {
  local sec="$1"
  echo ">> Generating load for ${sec}s (P=${CONC})"
  local end=$(( $(date +%s) + sec ))
  while [ "$(date +%s)" -lt "${end}" ]; do
    seq 100 | xargs -I{} -P"${CONC}" \
      curl -sk --resolve "${HOST}:${PORT}:${ADDR}" "https://${HOST}:${PORT}/" -o /dev/null
  done
  echo "   ...load phase done."
}

echo "Namespace: ${NS} | VirtualService: ${VS} | Host: ${HOST}:${PORT}"
echo "If needed, ensure you have a port-forward running:"
echo "  kubectl -n istio-system port-forward svc/istio-ingressgateway ${PORT}:443 --address 127.0.0.1 >/tmp/pf_igw.log 2>&1 &"
echo

# 1) 100/0
patch_weight 100 0
print_dist
phase_load "${PHASE_SEC}"

# 2) 50/50
patch_weight 50 50
print_dist
phase_load "${PHASE_SEC}"

# 3) 0/100
patch_weight 0 100
print_dist
phase_load "${PHASE_SEC}"

echo
echo "=== Done ==="

