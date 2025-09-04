#!/usr/bin/env bash
# rollout_canary.sh
# - VirtualService 트래픽을 100/0 -> 50/50 -> 0/100 순서로 전환
# - 각 단계마다 간단 부하 + x-version 헤더 분포 출력
# - Grafana/Kiali 캡처용으로 단계별 대기(sleep) 포함

set -euo pipefail

# ==== 환경 변수 (필요시 수정) ====
NS="boutique"                 # 네임스페이스
VS="boutique-vs"              # VirtualService 이름
HOST="shop.local"             # Ingress 호스트 (SNI)
PORT="8443"                   # 로컬 포트포워드 받은 포트
ADDR="127.0.0.1"              # --resolve에 사용할 주소
VERIFY_HITS=200               # 분포 확인용 총 요청 수(작을수록 빠름)
CONC=20                       # 동시성 (xargs -P)
PHASE_SEC=20                  # 각 단계 유지 시간(초) - Grafana 캡처용
PROPAGATION_SEC=2             # VS 패치 후 전파 대기(초)

# ==== 함수들 ====
patch_weight () {
  local w1="$1"   # route[0] (보통 v1)
  local w2="$2"   # route[1] (보통 v2)
  echo
  echo ">> Patching weights: v1=${w1} / v2=${w2}"
  kubectl -n "${NS}" patch vs "${VS}" --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/http/0/route/0/weight\",\"value\":${w1}},
    {\"op\":\"replace\",\"path\":\"/spec/http/0/route/1/weight\",\"value\":${w2}}
  ]" >/dev/null
  echo "   ...applied. waiting ${PROPAGATION_SEC}s for propagation"
  sleep "${PROPAGATION_SEC}"
}

# 간단 분포 측정(헤더 x-version 카운트)
print_dist () {
  echo ">> Sampling x-version distribution (${VERIFY_HITS} hits, P=${CONC})"
  seq "${VERIFY_HITS}" | xargs -I{} -P"${CONC}" \
    curl -sk -D - --resolve "${HOST}:${PORT}:${ADDR}" "https://${HOST}:${PORT}/" -o /dev/null \
  | tr -d '\r' \
  | awk 'BEGIN{IGNORECASE=1} /^x-version:/{print}' \
  | sort | uniq -c
}

# 부하 발생(간단 루프) — Grafana/Kiali에 라인 그리기 용도
# 초당 대략 (VERIFY_HITS/PHASE_SEC) * (CONC/?) 정도의 요청이 발생
phase_load () {
  local sec="$1"
  echo ">> Generating load for ${sec}s (P=${CONC})"
  local end=$(( $(date +%s) + sec ))
  while [ "$(date +%s)" -lt "${end}" ]; do
    # 한 번에 몇십~몇백개 묶어서 보내기
    seq 100 | xargs -I{} -P"${CONC}" \
      curl -sk --resolve "${HOST}:${PORT}:${ADDR}" "https://${HOST}:${PORT}/" -o /dev/null
  done
  echo "   ...load phase done."
}

# ==== 실행 전 확인 ====
echo "Namespace: ${NS} | VirtualService: ${VS} | Host: ${HOST}:${PORT}"
echo "If needed, ensure you have a port-forward running:"
echo "  kubectl -n istio-system port-forward svc/istio-ingressgateway ${PORT}:443 --address 127.0.0.1 >/tmp/pf_igw.log 2>&1 &"
echo

# ==== 시나리오 시작: 100/0 -> 50/50 -> 0/100 ====

# 1) 100/0 (v1=100, v2=0)
patch_weight 100 0
print_dist
phase_load "${PHASE_SEC}"

# 2) 50/50
patch_weight 50 50
print_dist
phase_load "${PHASE_SEC}"

# 3) 0/100 (v2=100)
patch_weight 0 100
print_dist
phase_load "${PHASE_SEC}"

echo
echo "=== Done ==="
echo "마지막 상태는 v1=0 / v2=100 입니다."
echo "필요하면 아래처럼 복귀:"
echo "  kubectl -n ${NS} patch vs ${VS} --type=json -p='[
    {\"op\":\"replace\",\"path\":\"/spec/http/0/route/0/weight\",\"value\":100},
    {\"op\":\"replace\",\"path\":\"/spec/http/0/route/1/weight\",\"value\":0}
  ]'"

