#!/usr/bin/env bash
# canary_guard.sh
# - 시나리오 C: v2 헤더 트래픽에 delay 주입 → p95 측정
# - 시나리오 D: 에러율>THRESH_ERR 또는 p95>THRESH_P95 시 자동 롤백
# 요구: kubectl, jq, curl

set -euo pipefail

### ====== 기본 설정 (환경에 맞게 덮어써도 됨) ======
NS="${NS:-boutique}"
VS="${VS:-boutique-vs}"
HOST="${HOST:-shop.local}"
PORT="${PORT:-8443}"
ADDR="${ADDR:-127.0.0.1}"

# Grafana (Prometheus 데이터소스 통해 쿼리)
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3000}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"
PROM_DS_NAME="${PROM_DS_NAME:-Prometheus}"

# 시나리오 옵션
MODE="${MODE:-}"              # C | D
DELAY_MS="${DELAY_MS:-400}"   # C: 지연 ms
THRESH_P95="${THRESH_P95:-300}"   # D: p95 임계(ms)
THRESH_ERR="${THRESH_ERR:-2}"     # D: 에러율 임계(%)
POLL_SEC="${POLL_SEC:-10}"        # D: 폴링 주기
CONFIRM_TIMES="${CONFIRM_TIMES:-2}" # D: 연속 초과 횟수
LOAD_BASE_QPS="${LOAD_BASE_QPS:-200}"   # D: 기본 트래픽 per loop
LOAD_HDR_QPS="${LOAD_HDR_QPS:-40}"      # D: 헤더 트래픽 per loop

### ====== 유틸 ======
die(){ echo "[ERR] $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null || die "필요한 커맨드가 없습니다: $1"; }

need kubectl; need jq; need curl;

grafana_header(){ echo -n "Authorization: Bearer ${GRAFANA_TOKEN}"; }

get_prom_ds_id(){
  [[ -n "${GRAFANA_TOKEN}" ]] || die "GRAFANA_TOKEN 이 비었습니다."
  curl -fsS -H "$(grafana_header)" \
    "${GRAFANA_URL}/api/datasources/name/${PROM_DS_NAME}" \
    | jq -r .id
}

prom_query(){
  local q="$1"; local ds_id="$2"
  curl -fsS -H "$(grafana_header)" \
    --get "${GRAFANA_URL}/api/datasources/proxy/${ds_id}/api/v1/query" \
    --data-urlencode "query=${q}"
}

get_vs_index_by_name(){
  local name="$1"
  kubectl -n "$NS" get vs "$VS" -o json \
    | jq -r ".spec.http|to_entries[]|select(.value.name==\"${name}\")|.key"
}

set_weights(){
  local v1="$1" v2="$2" idx="$3"
  kubectl -n "$NS" patch vs "$VS" --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/http/${idx}/route/0/weight\",\"value\":${v1}},
    {\"op\":\"replace\",\"path\":\"/spec/http/${idx}/route/1/weight\",\"value\":${v2}}
  ]" >/dev/null
  echo "[OK] 가중치 설정: v1=${v1} v2=${v2}"
}

remove_fault(){
  local idx="$1"
  kubectl -n "$NS" patch vs "$VS" --type=json -p="[
    {\"op\":\"remove\",\"path\":\"/spec/http/${idx}/fault\"}
  ]" >/dev/null 2>&1 || true
}

apply_delay(){
  local idx="$1" ms="$2"
  remove_fault "$idx"
  kubectl -n "$NS" patch vs "$VS" --type=json -p="[
    {\"op\":\"add\",\"path\":\"/spec/http/${idx}/fault\",\"value\":{\"delay\":{\"fixedDelay\":\"${ms}ms\",\"percentage\":{\"value\":100}}}},
    {\"op\":\"add\",\"path\":\"/spec/http/${idx}/retries\",\"value\":{\"attempts\":0}}
  ]" >/dev/null 2>&1 || kubectl -n "$NS" patch vs "$VS" --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/http/${idx}/fault\",\"value\":{\"delay\":{\"fixedDelay\":\"${ms}ms\",\"percentage\":{\"value\":100}}}},
    {\"op\":\"replace\",\"path\":\"/spec/http/${idx}/retries\",\"value\":{\"attempts\":0}}
  ]" >/dev/null
  echo "[OK] delay=${ms}ms (x-canary 헤더 트래픽에만)"
}

apply_abort(){
  local idx="$1"
  remove_fault "$idx"
  kubectl -n "$NS" patch vs "$VS" --type=json -p="[
    {\"op\":\"add\",\"path\":\"/spec/http/${idx}/fault\",\"value\":{\"abort\":{\"httpStatus\":500,\"percentage\":{\"value\":100}}}},
    {\"op\":\"add\",\"path\":\"/spec/http/${idx}/retries\",\"value\":{\"attempts\":0}}
  ]" >/dev/null 2>&1 || kubectl -n "$NS" patch vs "$VS" --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/http/${idx}/fault\",\"value\":{\"abort\":{\"httpStatus\":500,\"percentage\":{\"value\":100}}}},
    {\"op\":\"replace\",\"path\":\"/spec/http/${idx}/retries\",\"value\":{\"attempts\":0}}
  ]" >/dev/null
  echo "[OK] abort=500 (x-canary 헤더 트래픽에만)"
}

local_p95_header(){
  # 헤더 트래픽 200회 time_total로 p95 근사
  local host="$HOST" port="$PORT" addr="$ADDR"
  seq 200 | xargs -I{} -P20 sh -c '
    curl -sk -w "%{time_total}\n" -o /dev/null \
      -H "x-canary: v2-fault" \
      --resolve '"$host"':'"$port"':'"$addr"' https://'"$host"':'"$port"'/ 
  ' | awk '{print $1*1000}' | sort -n \
    | awk '{a[NR]=$1} END{p=int(0.95*NR); if(p<1)p=1; printf("%.0f\n", a[p])}'
}

get_p95_ms(){
  local ds_id="$1"
  local q='histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket{destination_workload="frontend-v2",destination_workload_namespace="boutique",reporter="destination"}[5m])) by (le))
or (histogram_quantile(0.95, sum(rate(istio_request_duration_seconds_bucket{destination_workload="frontend-v2",destination_workload_namespace="boutique",reporter="destination"}[5m])) by (le))*1000)'
  prom_query "$q" "$ds_id" | jq -r '.data.result[0].value[1] // "NaN"'
}

get_error_rate(){
  local ds_id="$1"
  local q='100 * (sum(rate(istio_requests_total{destination_workload="frontend-v2",destination_workload_namespace="boutique",reporter="destination",response_code=~"5.."}[5m])) / sum(rate(istio_requests_total{destination_workload="frontend-v2",destination_workload_namespace="boutique",reporter="destination"}[5m])))'
  prom_query "$q" "$ds_id" | jq -r '.data.result[0].value[1] // "0"'
}

start_load_loops(){
  # A: 기본 트래픽
  (
    while true; do
      seq "${LOAD_BASE_QPS}" | xargs -I{} -P20 curl -sk -o /dev/null \
        --resolve "$HOST:$PORT:$ADDR" "https://$HOST:$PORT/" >/dev/null
      sleep 1
    done
  ) & BASE_PID=$!

  # B: 헤더 트래픽(모두 v2 경로)
  (
    while true; do
      seq "${LOAD_HDR_QPS}" | xargs -I{} -P20 curl -sk -o /dev/null \
        -H 'x-canary: v2-fault' \
        --resolve "$HOST:$PORT:$ADDR" "https://$HOST:$PORT/" >/dev/null
      sleep 1
    done
  ) & HDR_PID=$!

  echo "$BASE_PID $HDR_PID"
}

stop_load_loops(){
  kill "${BASE_PID:-0}" >/dev/null 2>&1 || true
  kill "${HDR_PID:-0}"  >/dev/null 2>&1 || true
}

usage(){
cat <<EOF
사용법:
  MODE=C  지연 주입 후 p95 측정
    env MODE=C [DELAY_MS=400] [THRESH_P95=300] ./canary_guard.sh

  MODE=D  임계치 초과 시 자동 롤백(에러율>THRESH_ERR 또는 p95>THRESH_P95)
    env MODE=D [THRESH_ERR=2] [THRESH_P95=300] [POLL_SEC=10] [CONFIRM_TIMES=2] ./canary_guard.sh

공통 ENV: NS VS HOST PORT ADDR, GRAFANA_URL GRAFANA_TOKEN PROM_DS_NAME
EOF
}

### ====== 본 실행 ======
[[ -z "${MODE}" ]] && { usage; exit 1; }

echo "[INFO] NS=$NS VS=$VS HOST=$HOST:$PORT ADDR=$ADDR"
# 인덱스 찾기
CANARY_IDX="$(get_vs_index_by_name canary-route || true)"
FAULT_IDX="$(get_vs_index_by_name v2-fault-when-header || true)"
[[ -z "$FAULT_IDX" ]] && die "v2-fault-when-header 라우트를 찾지 못했습니다."
[[ -z "$CANARY_IDX" ]] && die "canary-route 라우트를 찾지 못했습니다."

# Grafana/Prometheus DS 확인 (시나리오 D는 필수, C는 선택)
PROM_DS_ID=""
if [[ "$MODE" == "D" || -n "${GRAFANA_TOKEN}" ]]; then
  PROM_DS_ID="$(get_prom_ds_id)"
  [[ "$PROM_DS_ID" == "null" || -z "$PROM_DS_ID" ]] && die "Grafana 데이터소스 ID 조회 실패"
  echo "[INFO] PROM_DS_ID=$PROM_DS_ID"
fi

trap 'stop_load_loops' EXIT

if [[ "$MODE" == "C" ]]; then
  echo "[C] delay ${DELAY_MS}ms 주입 → p95 측정"
  apply_delay "$FAULT_IDX" "$DELAY_MS"
  sleep 3

  # 로컬 근사 p95
  P95_LOCAL="$(local_p95_header || echo NaN)"
  echo "[C] Local p95(ms) ≈ ${P95_LOCAL}"

  # Grafana p95 (가능하면)
  if [[ -n "${PROM_DS_ID}" ]]; then
    P95_GRAFANA="$(get_p95_ms "$PROM_DS_ID")"
    echo "[C] Grafana p95(ms) = ${P95_GRAFANA}"
  else
    echo "[C] Grafana 토큰 미지정 → p95(ms) 쿼리 생략"
  fi

  echo "[C] 임계=${THRESH_P95}ms, 권장판정: p95>=임계면 롤백"
  exit 0
fi

if [[ "$MODE" == "D" ]]; then
  echo "[D] 임계: 에러율>${THRESH_ERR}% 또는 p95>${THRESH_P95}ms → 즉시 롤백(v1=100,v2=0)"
  echo "[D] abort=500(헤더 트래픽)로 에러율 유도 가능"
  apply_abort "$FAULT_IDX"

  # 부하 시작
  read BASE_PID HDR_PID < <(start_load_loops)
  echo "[D] load PIDs: base=${BASE_PID} header=${HDR_PID}"

  EXCEED_COUNT=0
  while true; do
    sleep "$POLL_SEC"
    ERR="$(get_error_rate "$PROM_DS_ID" || echo 0)"
    P95="$(get_p95_ms "$PROM_DS_ID" || echo NaN)"

    # 숫자 파싱
    ERR_NUM="$(printf '%.2f' "${ERR:-0}")"
    P95_NUM="$(printf '%.0f' "${P95:-0}")"

    printf "[D] err=%.2f%%  p95=%sms (thresholds: %s%% / %sms)\n" "$ERR_NUM" "$P95_NUM" "$THRESH_ERR" "$THRESH_P95"

    OVER=0
    awk -v e="$ERR_NUM" -v et="$THRESH_ERR" 'BEGIN{exit !(e>et)}' && OVER=1 || true
    awk -v p="$P95_NUM" -v pt="$THRESH_P95" 'BEGIN{exit !(p>pt)}' && OVER=1 || true

    if [[ "$OVER" -eq 1 ]]; then
      EXCEED_COUNT=$((EXCEED_COUNT+1))
      echo "[D] 임계 초과 감지 (${EXCEED_COUNT}/${CONFIRM_TIMES})"
    else
      EXCEED_COUNT=0
    fi

    if [[ "$EXCEED_COUNT" -ge "$CONFIRM_TIMES" ]]; then
      echo "[D] 기준 충족 → 롤백 실행"
      set_weights 100 0 "$CANARY_IDX"
      stop_load_loops
      echo "[D] 완료. 필요하면 fault 제거:"
      echo "    kubectl -n $NS patch vs $VS --type=json -p='[{\"op\":\"remove\",\"path\":\"/spec/http/${FAULT_IDX}/fault\"}]' 2>/dev/null || true"
      exit 0
    fi
  done
fi

