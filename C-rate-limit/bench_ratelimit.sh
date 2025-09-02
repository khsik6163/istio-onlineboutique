#!/usr/bin/env bash
# bench_ratelimit.sh - Istio Ingress rate-limit 응답 코드 분포 측정기
# Usage examples:
#   ./bench_ratelimit.sh -m local -n 200
#   ./bench_ratelimit.sh -m incluster -n 200
# 옵션: -m {local|incluster} -n 요청수 -P 경로 -H 호스트명 -o 출력디렉토리
# 환경변수로 라벨링: MAX_TOKENS, FILL_RATE 등 (리포트 파일명에 기록)

set -euo pipefail

MODE="local"                  # local | incluster
REQS=100
HOST="shop.local"
PATH_URI="/"
ISTIO_NS="istio-system"
SLEEP_NS="default"
OUTDIR="./out"
PORT="8443"                   # local 모드에서 로컬 수신포트
SVC_NAME="istio-ingressgateway"

log() { echo "[$(date +'%F %T')] $*"; }

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while getopts ":m:n:P:H:o:" opt; do
  case "$opt" in
    m) MODE="$OPTARG" ;;
    n) REQS="$OPTARG" ;;
    P) PATH_URI="$OPTARG" ;;
    H) HOST="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    *) usage ;;
  esac
done

mkdir -p "$OUTDIR"

TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
LABELS=""
[[ -n "${MAX_TOKENS:-}" ]] && LABELS+="_maxtok-${MAX_TOKENS}"
[[ -n "${FILL_RATE:-}"  ]] && LABELS+="_fill-${FILL_RATE}"
[[ -z "$LABELS" ]] && LABELS="_nolabel"

RAW_FILE="$OUTDIR/${TIMESTAMP}_${MODE}${LABELS}_codes.txt"
CSV_FILE="$OUTDIR/${TIMESTAMP}_${MODE}${LABELS}_summary.csv"
SUM_FILE="$OUTDIR/${TIMESTAMP}_${MODE}${LABELS}_summary.txt"

summarize() {
  local infile="$1"
  local total
  total=$(wc -l < "$infile" | awk '{print $1}')
  if [[ "$total" -eq 0 ]]; then
    echo "no data" > "$SUM_FILE"
    return
  fi

  {
    echo "code,count,percent"
    awk '{a[$1]++} END{for(k in a) printf "%s,%d,%.2f%%\n", k, a[k], (a[k]/t*100)}' t="$total" "$infile" \
      | sort -t, -k1
  } > "$CSV_FILE"

  {
    echo "== Summary =="
    echo "mode      : $MODE"
    echo "host      : $HOST"
    echo "path      : $PATH_URI"
    echo "requests  : $total"
    [[ -n "${MAX_TOKENS:-}" ]] && echo "MAX_TOKENS: $MAX_TOKENS"
    [[ -n "${FILL_RATE:-}"  ]] && echo "FILL_RATE : $FILL_RATE"
    echo
    column -t -s, "$CSV_FILE"
  } > "$SUM_FILE"

  log "saved raw: $RAW_FILE"
  log "saved csv: $CSV_FILE"
  log "saved txt: $SUM_FILE"
  log "quick view:"
  cat "$SUM_FILE"
}

pf_pid=""
pf_start() {
  # local 모드: 8443 → ingress 443 포트포워딩
  log "starting port-forward 127.0.0.1:$PORT -> $SVC_NAME:443"
  kubectl -n "$ISTIO_NS" port-forward "svc/$SVC_NAME" "$PORT:443" --address 127.0.0.1 >/tmp/pf_igw.log 2>&1 &
  pf_pid=$!
  sleep 1
  if ! kill -0 "$pf_pid" 2>/dev/null; then
    log "port-forward failed. log:"
    tail -n +1 /tmp/pf_igw.log || true
    exit 1
  fi
}

pf_stop() {
  [[ -n "${pf_pid:-}" ]] && kill "$pf_pid" 2>/dev/null || true
}

run_local() {
  # /etc/hosts 에 127.0.0.1 shop.local 있어야 함.
  pf_start
  trap pf_stop EXIT

  local url="https://${HOST}:${PORT}${PATH_URI}"
  log "sending $REQS requests to ${url}"
  : > "$RAW_FILE"
  for i in $(seq 1 "$REQS"); do
    curl -sk -o /dev/null -w "%{http_code}\n" "$url" >> "$RAW_FILE" || echo "000" >> "$RAW_FILE"
  done
}

run_incluster() {
  # 클러스터 내부에서 SNI=HOST 로 HTTPS. --resolve로 ClusterIP 바인딩
  local ip
  ip=$(kubectl -n "$ISTIO_NS" get svc "$SVC_NAME" -o jsonpath='{.spec.clusterIP}')
  if [[ -z "$ip" ]]; then
    log "failed to get ClusterIP of $SVC_NAME"
    exit 1
  fi
  local S
  S=$(kubectl -n "$SLEEP_NS" get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')
  if [[ -z "$S" ]]; then
    log "sleep pod not found in ns=$SLEEP_NS"
    exit 1
  fi

  log "in-cluster test via sleep pod: SNI=$HOST, resolve $HOST:443 -> $ip"
  kubectl -n "$SLEEP_NS" exec "$S" -c sleep -- sh -lc \
    "for i in \$(seq 1 $REQS); do curl -sk --resolve $HOST:443:$ip https://$HOST$PATH_URI -o /dev/null -w \"%{http_code}\n\" || echo 000; done" \
    > "$RAW_FILE"
}

case "$MODE" in
  local)     run_local ;;
  incluster) run_incluster ;;
  *) log "unknown mode: $MODE"; usage ;;
esac

summarize "$RAW_FILE"

