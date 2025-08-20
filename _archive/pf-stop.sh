#!/usr/bin/env bash
set -euo pipefail
LOGDIR="${TMPDIR:-/tmp}/pf-istio"
for name in grafana kiali jaeger; do
  PIDFILE="${LOGDIR}/${name}.pid"
  if [[ -f "$PIDFILE" ]]; then
    PID=$(cat "$PIDFILE" || true)
    if [[ -n "${PID:-}" ]] && ps -p "$PID" >/dev/null 2>&1; then
      echo "Killing $name (pid $PID)"
      kill "$PID" || true
    fi
    rm -f "$PIDFILE"
  fi
done
echo "Done."

