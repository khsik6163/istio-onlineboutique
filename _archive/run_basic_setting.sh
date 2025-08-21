#!/usr/bin/env bash
set -euo pipefail

echo "=== 0) 환경 점검 ==========================================="
command -v kind >/dev/null      || { echo "❌ kind 미설치"; exit 1; }
command -v kubectl >/dev/null   || { echo "❌ kubectl 미설치"; exit 1; }
command -v istioctl >/dev/null  || { echo "❌ istioctl 미설치"; exit 1; }

echo "=== 1) Kind 클러스터 재생성 ================================"
kind delete cluster || true
kind create cluster

echo "=== 2) Istio(demo 프로파일) 설치 ============================"
istioctl install -y --set profile=demo

echo "=== 3) Addons(Prometheus/Grafana/Kiali/Jaeger) 설치 ========="
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.26/samples/addons/prometheus.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.26/samples/addons/grafana.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.26/samples/addons/kiali.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.26/samples/addons/jaeger.yaml

echo "=== 4) 네임스페이스/사이드카 주입 라벨 ======================"
kubectl create ns boutique || true
kubectl label ns boutique istio-injection=enabled --overwrite
kubectl label ns default  istio-injection=enabled --overwrite

echo "=== 5) Online Boutique & sleep 배포 ========================"
kubectl -n boutique apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.26/samples/sleep/sleep.yaml

echo "=== 6) 트레이싱(meshConfig + Telemetry) 설정 ==============="
cat <<'YAML' | istioctl install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: demo
  meshConfig:
    # Envoy에 Zipkin(=Jaeger 호환) 수집기 주소와 샘플링 적용
    defaultConfig:
      tracing:
        sampling: 100
        zipkin:
          address: zipkin.istio-system.svc.cluster.local:9411
    # Telemetry에서 참조할 provider 등록
    extensionProviders:
    - name: jaeger
      zipkin:
        service: zipkin.istio-system.svc.cluster.local
        port: 9411
YAML

kubectl -n istio-system apply -f - <<'YAML'
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: mesh-tracing
spec:
  tracing:
  - providers:
    - name: jaeger
    randomSamplingPercentage: 100
YAML

echo "=== 7) 내부 통신용 VS(80→프록시→8080) 적용 ================"
kubectl -n boutique apply -f - <<'YAML'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: frontend-internal
spec:
  hosts:
  - frontend.boutique.svc.cluster.local
  http:
  - route:
    - destination:
        host: frontend.boutique.svc.cluster.local
        port:
          number: 80
YAML

echo "=== 8) 워크로드 롤링 재시작(부트스트랩 반영) ================"
kubectl -n boutique rollout restart deploy
kubectl -n default  rollout restart deploy

echo "=== 9) 준비 대기 =========================================="
kubectl -n istio-system rollout status deploy/istiod --timeout=180s
kubectl -n istio-system rollout status deploy/kiali --timeout=180s
kubectl -n istio-system rollout status deploy/grafana --timeout=180s
kubectl -n istio-system rollout status deploy/jaeger --timeout=180s || true
kubectl -n boutique rollout status deploy/frontend --timeout=300s
kubectl -n default  rollout status deploy/sleep --timeout=300s

echo "=== 10) 헬스체크 & 트래픽 흘리기 ============================"
SLEEP_POD=$(kubectl -n default get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')
# 서비스(80)로 요청 → 사이드카가 8080으로 라우트
kubectl -n default exec -i "$SLEEP_POD" -c sleep -- curl -sI http://frontend.boutique.svc.cluster.local | head -n1

# 트래픽 조금 흘려서 스팬 생성
for i in $(seq 30); do
  kubectl -n default exec -i "$SLEEP_POD" -c sleep -- curl -s http://frontend.boutique.svc.cluster.local >/dev/null || true
done

echo "=== 11) 포트포워딩 시작(백그라운드) ========================="
# 필요한 것만 켜도 됨. PID는 /tmp 에 저장.
kubectl -n istio-system port-forward svc/kiali   20001:20001 >/tmp/pf-kiali.log 2>&1 &  echo $! > /tmp/pf-kiali.pid
kubectl -n istio-system port-forward svc/grafana 3000:3000  >/tmp/pf-grafana.log 2>&1 & echo $! > /tmp/pf-grafana.pid
kubectl -n istio-system port-forward svc/tracing 16686:80   >/tmp/pf-jaeger.log 2>&1 &  echo $! > /tmp/pf-jaeger.pid

sleep 2
echo "=== 12) Jaeger 서비스 목록 확인 ============================"
if command -v jq >/dev/null; then
  curl -sS http://localhost:16686/jaeger/api/services | jq .
else
  curl -sS http://localhost:16686/jaeger/api/services || true
fi

cat <<'TXT'

────────────────────────────────────────────────────────
✅ 완료!

대시보드:
- Kiali   → http://localhost:20001
- Grafana → http://localhost:3000
- Jaeger  → http://localhost:16686/jaeger  (Service 드롭다운 확인)

포트포워딩 종료:
  lsof -ti :20001,:3000,:16686 | xargs -r kill

부하(LoadGenerator) ON/OFF:
  kubectl -n boutique scale deploy/loadgenerator --replicas=1
  kubectl -n boutique scale deploy/loadgenerator --replicas=0
────────────────────────────────────────────────────────
TXT

