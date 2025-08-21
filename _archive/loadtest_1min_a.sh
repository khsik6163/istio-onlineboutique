#!/usr/bin/env bash

URL="https://shop.local:8443/"
DURATION=60   # 초 단위 (1분)

echo "=== $DURATION초 동안 $URL 에 트래픽 발생 ==="
END=$((SECONDS + DURATION))

while [ $SECONDS -lt $END ]; do
  curl -sk -o /dev/null -w "%{http_code}\n" "$URL" \
  | grep -v 200 && echo "❌ 실패"
  sleep 0.2   # 0.2초마다 1요청 (≈ 5req/sec)
done

echo "완료!"

