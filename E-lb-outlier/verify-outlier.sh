#!/usr/bin/env bash
# istio outlierDetection 자동 퇴출 검증 스크립트
# 전제: default 네임스페이스에 httpbin v1/v2, sleep, DR/VS가 이미 적용됨
# - DR: consecutive5xxErrors=1, interval=1s, baseEjectionTime=30s 등
# - VS: 기본 v1(/status/200), 헤더 x-err:1 → v2(/status/500)

set -euo pipefail

NS=${NS:-default}
FQDN="httpbin.${NS}.svc.cluster.local"
PORT=8000
SUBSET_CLUSTER="outbound|${PORT}|subset=v2|${FQDN}"
BASIC_CLUSTER="outbound|${PORT}||${FQDN}"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }

echo "=== 0) 의존성 확인 =========================================="
command -v kubectl >/dev/null   || { red "❌ kubectl 미설치"; exit 1; }
command -v istioctl >/dev/null  || { red "❌ istioctl 미설치"; exit 1; }

echo "=== 1) sleep 파드 식별 ======================================"
SLEEP_POD=$(kubectl -n "${NS}" get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')
[[ -n "${SLEEP_POD}" ]] || { red "❌ sleep 파드 없음"; exit 1; }
echo "sleep pod: ${SLEEP_POD}"

echo "=== 2) 서브셋 클러스터 존재 확인(워밍업) ====================="
# Envoy가 subset 클러스터를 확실히 생성하도록 /warmup 경로로 v1/v2 둘 다 접근
kubectl -n "${NS}" exec -i "${SLEEP_POD}" -c sleep -- \
  curl -s -o /dev/null -w "%{http_code}\n" "http://${FQDN}:${PORT}/warmup" || true
kubectl -n "${NS}" exec -i "${SLEEP_POD}" -c sleep -- \
  curl -s -H 'x-err: 1' -o /dev/null -w "%{http_code}\n" "http://${FQDN}:${PORT}/warmup" || true

echo "=== 3) 기본 동작 확인(v1=200 / v2=500) ======================"
CODE_V1=$(kubectl -n "${NS}" exec -i "${SLEEP_POD}" -c sleep -- \
  curl -s -o /dev/null -w "%{http_code}" "http://${FQDN}:${PORT}")
CODE_V2=$(kubectl -n "${NS}" exec -i "${SLEEP_POD}" -c sleep -- \
  curl -s -H 'x-err: 1' -o /dev/null -w "%{http_code}" "http://${FQDN}:${PORT}" || true)
echo "v1(예상 200): ${CODE_V1} / v2(예상 500): ${CODE_V2}"

echo "=== 4) 에러 트래픽 집중(퇴출 유도) ==========================="
for i in $(seq 20); do
  kubectl -n "${NS}" exec -i "${SLEEP_POD}" -c sleep -- \
    curl -s -H 'x-err: 1' -o /dev/null -w "%{http_code}\n" "http://${FQDN}:${PORT}" || true
done

echo "=== 5) 퇴출 폴링 확인(subset=v2 활성 호스트=0) ==============="
# Envoy admin JSON에서 subset=v2 클러스터의 host_statuses 길이를 확인(0이면 ejected 상태)
POLL_MAX=${POLL_MAX:-45} # 초
SLEEP_SEC=1
EJECT_SEEN=0

for _ in $(seq "${POLL_MAX}"); do
  COUNT=$(kubectl -n "${NS}" exec "${SLEEP_POD}" -c istio-proxy -- \
    pilot-agent request GET '/clusters?format=json' 2>/dev/null \
    | jq '[.cluster_statuses[]
            | select(.name|contains("'"subset=v2|${FQDN}"'"))
            | .host_statuses] | length' 2>/dev/null || echo "NA")

  if [[ "${COUNT}" != "NA" && "${COUNT}" -eq 0 ]]; then
    EJECT_SEEN=1
    break
  fi
  sleep "${SLEEP_SEC}"
done

# 참고 출력(디버그): 클러스터 목록과 엔드포인트 스냅샷
echo "--- 디버그: subset/v2 클러스터 이름 존재 여부 ---------------------"
istioctl proxy-config clusters "${SLEEP_POD}" -n "${NS}" --fqdn "${FQDN}" --port "${PORT}" || true
echo "--- 디버그: subset=v2 엔드포인트 테이블 --------------------------"
istioctl proxy-config endpoints "${SLEEP_POD}" -n "${NS}" --cluster "${SUBSET_CLUSTER}" || true
echo "--- 디버그: 기본(묶음) 엔드포인트 테이블 --------------------------"
istioctl proxy-config endpoints "${SLEEP_POD}" -n "${NS}" --cluster "${BASIC_CLUSTER}" || true

echo "=== 6) outlier 통계(가능 시) =================================="
kubectl -n "${NS}" exec "${SLEEP_POD}" -c istio-proxy -- \
  pilot-agent request GET stats \
  | grep "cluster.outbound|${PORT}|subset=v2|${FQDN}.*outlier_detection" || true

echo "=== 7) 현재 v2 접근 시 응답코드(대개 503 기대) ================"
NOW_V2=$(kubectl -n "${NS}" exec -i "${SLEEP_POD}" -c sleep -- \
  curl -s -H 'x-err: 1' -o /dev/null -w "%{http_code}" "http://${FQDN}:${PORT}" || true)
echo "v2 현재 응답: ${NOW_V2}"

echo "=== 결과 ====================================================="
if [[ "${EJECT_SEEN}" -eq 1 ]]; then
  green "✅ PASS: subset=v2 활성 호스트=0 → 아웃라이어 자동 퇴출 확인됨"
  exit 0
else
  yellow "⚠️  FAIL: 폴링 ${POLL_MAX}s 내에 subset=v2 활성 호스트=0을 확인하지 못함"
  echo "      - DR 파라미터(consecutive5xxErrors/interval/baseEjectionTime)와 VS 라우팅을 재확인하시오."
  echo "      - 에러 트래픽이 정말 v2로 갔는지(x-err:1 헤더) 확인하시오."
  echo "      - 필요 시 DR에 splitExternalLocalOriginErrors / consecutiveLocalOriginFailures 조합을 검토."
  exit 1
fi

