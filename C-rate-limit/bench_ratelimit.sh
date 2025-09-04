#!/usr/bin/env bash
set -euo pipefail

# ---- 설정 ----
REQS="${REQS:-100}"           # 총 요청 수 (기본 100)
CONCURRENCY="${CONCURRENCY:-20}"  # 동시성
HOST="${HOST:-shop.local}"
PORT="${PORT:-8443}"
PATH_="${PATH_:-/}"           # 경로 (예: /api)
OUTDIR="${OUTDIR:-./out}"
MODE="${MODE:-local}"         # 라벨용

mkdir -p "$OUTDIR"

ts() { date +"%Y%m%d_%H%M%S"; }
log() { echo "[$(date '+%F %T')] $*"; }

# ---- 포트포워딩 정리/시작 ----
pkill -f "port-forward.*${PORT}" 2>/dev/null || true
sleep 0.3
log "starting port-forward 127.0.0.1:${PORT} -> istio-ingressgateway:443"
kubectl -n istio-system port-forward svc/istio-ingressgateway "${PORT}:443" --address 127.0.0.1 \
  > /tmp/pf_igw_${PORT}.log 2>&1 &
PF_PID=$!
sleep 1

# 살아있는지 확인
if ! lsof -n -iTCP:${PORT} -sTCP:LISTEN >/dev/null 2>&1; then
  log "port-forward failed. log:"
  cat /tmp/pf_igw_${PORT}.log || true
  exit 1
fi

# ---- 단일 헬스체크 ----
if ! CODE=$(curl -sk --max-time 5 \
  --http1.1 --no-keepalive \
  --resolve "${HOST}:${PORT}:127.0.0.1" \
  "https://${HOST}:${PORT}${PATH_}" -o /dev/null -w "%{http_code}"); then
  log "single request failed. pf log:"
  tail -n +1 /tmp/pf_igw_${PORT}.log || true
  kill ${PF_PID} 2>/dev/null || true
  exit 1
fi
log "single request => ${CODE}"

# ---- 부하 전송 ----
STAMP=$(ts)
CODES_FILE="${OUTDIR}/${STAMP}_${MODE}_codes.txt"
SUMMARY_TXT="${OUTDIR}/${STAMP}_${MODE}_summary.txt"
SUMMARY_CSV="${OUTDIR}/${STAMP}_${MODE}_summary.csv"

log "sending ${REQS} requests to https://${HOST}:${PORT}${PATH_} (c=${CONCURRENCY})"

# xargs 병렬로 안전하게 전송
# - 각 요청은 독립 커넥션/세션 (--no-keepalive, --http1.1)
# - 실패 시도 0으로 만들지 않도록 --max-time 추가
seq 1 "${REQS}" | xargs -I{} -P "${CONCURRENCY}" \
  curl -sk --max-time 5 \
    --http1.1 --no-keepalive \
    --resolve "${HOST}:${PORT}:127.0.0.1" \
    "https://${HOST}:${PORT}${PATH_}" \
    -o /dev/null -w "%{http_code}\n" \
  > "${CODES_FILE}"

# ---- 요약 ----
TOTAL=$(wc -l < "${CODES_FILE}")
OK=$(grep -c '^200$' "${CODES_FILE}" || true)
RL=$(grep -c '^429$' "${CODES_FILE}" || true)
OTH=$(( TOTAL - OK - RL ))

pct() { awk -v a="$1" -v b="$2" 'BEGIN{ if(b==0) print "0.00"; else printf "%.2f", (a/b)*100 }'; }

PCT_OK=$(pct "$OK" "$TOTAL")
PCT_RL=$(pct "$RL" "$TOTAL")
PCT_OTH=$(pct "$OTH" "$TOTAL")

{
  echo "== Summary =="
  echo "mode      : ${MODE}"
  echo "host      : ${HOST}"
  echo "path      : ${PATH_}"
  echo "requests  : ${TOTAL}"
  echo
  echo "code  count  percent"
  printf "200   %-6d %s%%\n" "${OK}" "${PCT_OK}"
  printf "429   %-6d %s%%\n" "${RL}" "${PCT_RL}"
  printf "other %-6d %s%%\n" "${OTH}" "${PCT_OTH}"
} | tee "${SUMMARY_TXT}" >/dev/null

{
  echo "code,count,percent"
  echo "200,${OK},${PCT_OK}"
  echo "429,${RL},${PCT_RL}"
  echo "other,${OTH},${PCT_OTH}"
} > "${SUMMARY_CSV}"

log "saved raw: ${CODES_FILE}"
log "saved txt: ${SUMMARY_TXT}"
log "saved csv: ${SUMMARY_CSV}"

# ---- 정리 ----
kill ${PF_PID} 2>/dev/null || true

