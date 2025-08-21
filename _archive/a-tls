# 1) 키/인증서
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -subj "/CN=shop.local" \
  -keyout shop.local.key -out shop.local.crt

# 2) istio-system에 TLS 시크릿
kubectl -n istio-system create secret tls shop-credential \
  --key shop.local.key --cert shop.local.crt --dry-run=client -o yaml | kubectl apply -f -


