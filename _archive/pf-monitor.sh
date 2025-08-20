#!/usr/bin/env bash
set -euo pipefail

NS=istio-system
LOGDIR="${TMPDIR:-/tmp}/pf-istio"
mkdir -p "$LOGDIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[!] $1 not found"; exit 1; }; }
need kubectl
need lsof

# 간단 헬스체크: 서비스/포드 존재?
echo "[*] Checking monitoring addons in namespace: ${NS}"
kubectl get svc -n "$NS" grafana kiali || true
kubectl get svc -n "$NS" tracing jaeger-query 2>/dev/null || true
kubectl get pods -n "$NS" | egrep 'grafana|kiali|jaeger' || true
echo

start_pf () {
  local name=$1 svc=$2 local=$3 remote=$4
  echo "[*] Port-forward $name  localhost:${local} -> ${svc}:${remote}"
  if lsof -iTCP:${local} -sTCP:LISTEN >/dev/null 2>&1; then
    echo "    - port ${local} already in use, skipping"
    return 0
  fi
  nohup kubectl -n "$NS" port-forward "svc/${svc}" "${local}:${remote}" \
    > "${LOGDIR}/${name}.log" 2>&1 &
  echo $! > "${LOGDIR}/${name}.pid"
}

# Jaeger 서비스 감지 (Istio 애드온은 svc/tracing, 일부 배포는 jaeger-query)
JAEGER_SVC=""
JAEGER_REMOTE=16686
if kubectl -n "$NS" get svc tracing >/dev/null 2>&1; then
  JAEGER_SVC="tracing"
  JAEGER_REMOTE=80          # ← 애드온 기본: 16686(local) -> 80(service)
elif kubectl -n "$NS" get svc jaeger-query >/dev/null 2>&1; then
  JAEGER_SVC="jaeger-query" # ← 16686(local) -> 16686(service)
  JAEGER_REMOTE=16686
else
  echo "[!] Jaeger service not found in ${NS}. Install the addon first."
  exit 1
fi

start_pf "grafana" "grafana" 3000 3000
start_pf "kiali"   "kiali"   20001 20001
start_pf "jaeger"  "${JAEGER_SVC}" 16686 ${JAEGER_REMOTE}

echo
echo "=== URLs ==="
echo " Grafana : http://localhost:3000"
echo " Kiali   : http://localhost:20001"
echo " Jaeger  : http://localhost:16686"
echo
echo "Logs: ${LOGDIR}/*.log"
echo
case "${1:-}" in
  open)
    # macOS 브라우저 자동 열기
    command -v open >/dev/null 2>&1 && open http://localhost:3000 http://localhost:20001 http://localhost:16686 || true
    ;;
esac

