#!/usr/bin/env bash
# fault_canary_guard.sh
# - Online Boutique + Istio
# - v2 전용 헤더 라우트에 Delay/Abort 주입 → Grafana 지표(p95/에러율)로 판단 → 필요시 롤백
# - 기본 트래픽은 v1=100/v2=0 유지(일반 사용자 영향 최소화), 헤더 트래픽(x-canary: v2-fault)만 주입 적용

set -euo pipefail

### ====== 사용자 환경 변수(필요시 덮어쓰기) ======
NS="${NS:-boutique}"                          # 네임스페이스
VS="${VS:-boutique-vs}"                       # VirtualService 이름
FAULT_ROUTE_NAME="${FAULT_ROUTE_NAME:-v2-fault-when-header}"   # 헤더-매치 라우트 이름
CANARY_ROUTE_NAME="${CANARY_ROUTE_NAME:-canary-route}"         # 기본 카나리 라우트 이름

HOST="${HOST:-shop.local}"                    # Ingress 호스트
ADDR="${ADDR:-127.0.0.1}"                     # 로컬 주소
PORT="${PORT:-8443}"                          # 포트포워드 받은 포트

# 모드: C(Delay), D(Abort), NONE(주입 제거)
MODE="${MODE:-C}"
DELAY_MS="${DELAY_MS:-400}"                   # MODE=C일 때 지연(ms)
TH_P95="${TH_P95:-300}"                       # 롤백 임계: p95(ms)
TH_ERR="${TH_ERR:-2}"                         # 롤백 임계: 에러율(%)
WARMUP_SEC="${WARMUP_SEC:-45}"                # 헤더 트래픽 워밍업 시간(초)
CONC="${CONC:-40}"                            # 동시성
LOAD_BATCH="${LOAD_BATCH:-400}"               # 한 번에 보낼 요청 수

# Grafana (반드시 세팅 필요)
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3000}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:?GRAFANA_TOKEN 환경변수 필요}"
PROM_DS_NAME="${PROM_DS_NAME:-Prometheus}"
PROM_DS_ID="${PROM_DS_ID:-}"

### ====== 유틸 ======
need() { command -v "$1" >/dev/null 2>&1 || { echo "[ERR] '$1' 필요"; exit 1; }; }
need kubectl; need jq; need curl; need awk; need tr; need sort; need uniq; need xargs; need seq

log() { echo -e "$@"; }
json_patch() { kubectl -n "$NS" patch vs "$VS" --type=json -p="$1" >/dev/null; }

get_http_index_by_name() {
  local name="$1"
  kubectl -n "$NS" get vs "$VS" -o json \
  | jq -r --arg n "$name" '.spec.http|to_entries[]|select(.value.name==$n)|.key'
}

set_weights() {
  local canary_idx="$1" w1="$2" w2="$3"
  log "[INFO] Patch weights: v1=${w1} v2=${w2}"
  json_patch "[
    {\"op\":\"replace\",\"path\":\"/spec/http/${canary_idx}/route/0/weight\",\"value\":${w1}},
    {\"op\":\"replace\",\"path\":\"/spec/http/${canary_idx}/route/1/weight\",\"value\":${w2}}
  ]"
}

ensure_retries_zero() {
  local fault_idx="$1"
  json_patch "[
    {\"op\":\"replace\",\"path\":\"/spec/http/${fault_idx}/retries\",\"value\":{\"attempts\":0}}
  ]" || true
}

apply_delay() {
  local fault_idx="$1" ms="$2"
  log "[INFO] Fault=delay ${ms}ms @ http[${fault_idx}]"
  json_patch "[
    {\"op\":\"replace\",\"path\":\"/spec/http/${fault_idx}/fault\",\"value\":
      {\"delay\":{\"fixedDelay\":\"${ms}ms\",\"percentage\":{\"value\":100}}}
    }
  ]"
  ensure_retries_zero "$fault_idx"
}

apply_abort500() {
  local fault_idx="$1"
  log "[INFO] Fault=abort 500 @ http[${fault_idx}]"
  json_patch "[
    {\"op\":\"replace\",\"path\":\"/spec/http/${fault_idx}/fault\",\"value\":
      {\"abort\":{\"httpStatus\":500,\"percentage\":{\"value\":100}}}
    }
  ]"
  ensure_retries_zero "$fault_idx"
}

remove_fault() {
  local fault_idx="$1"
  log "[INFO] Remove fault @ http[${fault_idx}]"
  json_patch "[
    {\"op\":\"remove\",\"path\":\"/spec/http/${fault_idx}/fault\"}
  ]" || true
}

show_routes() {
  kubectl -n "$NS" get vs "$VS" -o json \
  | jq -r '.spec.http
  | to_entries
  | map("\(.key): \(.value.name) | " + (.value.route|map("\(.destination.subset)=\(.weight)")|join(" ")))
  | .[]'
}

warmup_header_traffic() {
  local end=$(( $(date +%s) + WARMUP_SEC ))
  log "[INFO] Warmup ${WARMUP_SEC}s header traffic (x-canary: v2-fault)"
  while [ "$(date +%s)" -lt "$end" ]; do
    seq "$LOAD_BATCH" | xargs -I{} -P"$CONC" \
      curl -sk -o /dev/null -H 'x-canary: v2-fault' \
      --resolve "${HOST}:${PORT}:${ADDR}" "https://${HOST}:${PORT}/"
  done
}

# Grafana → Prometheus 쿼리 헬퍼
grafana_query() {
  local q="$1"
  curl -fsS -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
    --get "${GRAFANA_URL}/api/datasources/proxy/${PROM_DS_ID}/api/v1/query" \
    --data-urlencode "query=${q}"
}

pick_prom_ds_id() {
  if [ -n "${PROM_DS_ID}" ]; then
    echo "$PROM_DS_ID"
    return
  fi
  curl -fsS -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
    "${GRAFANA_URL}/api/datasources/name/${PROM_DS_NAME}" \
  | jq -r '.id'
}
measure_ingress() {
  # p95(ms): ingress(istio-ingressgateway) -> frontend-external 만 집계
  local Q_P95='histogram_quantile(0.95,
    sum by (le) (
      rate(istio_request_duration_milliseconds_bucket{
        reporter="source",
        source_workload="istio-ingressgateway",
        destination_service_name="frontend-external",
        destination_service_namespace="boutique"
      }[1m])
    )
  )'

  # error rate(%): 같은 경로의 5xx 비율 (이미 맞는 형태였음)
  local Q_ERR='100 * (
    sum(rate(istio_requests_total{
      reporter="source",
      source_workload="istio-ingressgateway",
      destination_service_name="frontend-external",
      destination_service_namespace="boutique",
      response_code=~"5.."
    }[1m]))
    /
    sum(rate(istio_requests_total{
      reporter="source",
      source_workload="istio-ingressgateway",
      destination_service_name="frontend-external",
      destination_service_namespace="boutique"
    }[1m]))
  )'

  local p95 err
  p95=$(grafana_query "$Q_P95" | jq -r '.data.result[0].value[1] // "NaN"')
  err=$(grafana_query "$Q_ERR" | jq -r '.data.result[0].value[1] // "0"')

  if [[ "$p95" == "NaN" || -z "$p95" ]]; then p95="0"; fi
  if [[ -z "$err" ]]; then err="0"; fi

  local p95_num err_num
  p95_num=$(printf '%.6f' "$p95")
  err_num=$(printf '%.6f' "$err")
  echo "$p95_num" "$err_num"
}


### ====== 메인 ======
log "[INFO] NS=${NS} VS=${VS} HOST=${HOST}:${PORT} ADDR=${ADDR}"

# Prometheus 데이터소스 ID
PROM_DS_ID="$(pick_prom_ds_id)"
[ -n "$PROM_DS_ID" ] || { echo "[ERR] Grafana Prometheus 데이터소스 ID 파악 실패"; exit 1; }
log "[INFO] PROM_DS_ID=${PROM_DS_ID}"

# 라우트 인덱스 확인
FAULT_IDX="$(get_http_index_by_name "$FAULT_ROUTE_NAME")"
CANARY_IDX="$(get_http_index_by_name "$CANARY_ROUTE_NAME")"
[ -n "$FAULT_IDX" ]  || { echo "[ERR] Fault 라우트(${FAULT_ROUTE_NAME}) 미발견"; exit 1; }
[ -n "$CANARY_IDX" ] || { echo "[ERR] Canary 라우트(${CANARY_ROUTE_NAME}) 미발견"; exit 1; }

# 기본 트래픽은 v1=100/v2=0으로 고정
set_weights "$CANARY_IDX" 100 0
sleep 2

case "$MODE" in
  C|c)
    apply_delay "$FAULT_IDX" "$DELAY_MS"
    ;;
  D|d)
    apply_abort500 "$FAULT_IDX"
    ;;
  NONE|none)
    remove_fault "$FAULT_IDX"
    ;;
  *)
    echo "[ERR] MODE는 C|D|NONE 중 하나여야 합니다"; exit 1;
    ;;
esac

log "[INFO] VS routes:"
show_routes

# NONE 모드면 주입만 제거하고 종료
if [[ "$MODE" =~ ^(NONE|none)$ ]]; then
  log "[DONE] Fault removed. Nothing to measure."
  exit 0
fi

# 헤더 트래픽 워밍업 → 측정
warmup_header_traffic
read P95 ERR <<<"$(measure_ingress)"
log "[MEASURE] ingress p95(ms)=${P95}  error_rate(%)=${ERR}"

# 판정 후 롤백
P95_INT=$(printf '%.0f' "$P95")
ERR_FLOAT=$(printf '%.2f' "$ERR")
if [ "$P95_INT" -gt "$TH_P95" ] || awk "BEGIN{exit !($ERR_FLOAT > $TH_ERR)}"; then
  log "[ACTION] ROLLBACK → v1=100 v2=0"
  set_weights "$CANARY_IDX" 100 0
else
  log "[ACTION] OK(임계 이하) → 유지"
fi

log "[DONE] 최종 VS 상태:"
show_routes

