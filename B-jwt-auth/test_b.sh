#!/usr/bin/env bash
set -euo pipefail

TOKEN=${TOKEN:-}
if [[ -z "${TOKEN}" ]]; then
  TOKEN=$(curl -fsSL https://raw.githubusercontent.com/istio/istio/release-1.26/security/tools/jwt/samples/demo.jwt)
fi





for i in {1..10000}; do
  if (( $i % 2 == 0 )); then
    # 짝수 → 토큰 있음 (200)
    curl -sk -o /dev/null -w "%{http_code}\n" \
      --resolve shop.local:8443:127.0.0.1 \
      -H "Authorization: Bearer $TOKEN" \
      https://shop.local:8443/
  else
    # 홀수 → 토큰 없음 (403)
    curl -sk -o /dev/null -w "%{http_code}\n" \
      --resolve shop.local:8443:127.0.0.1 \
      https://shop.local:8443/
  fi
done

