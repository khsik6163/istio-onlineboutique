# Online Boutique + Istio Graduation Project

이 저장소는 Google Online Boutique 샘플 애플리케이션을 기반으로 **Istio Service Mesh** 기능을 실험하고 졸업 작품으로 정리한 결과물입니다.  
실험은 4단계(A~D)로 나누어 수행되었습니다.

---

## 📌 프로젝트 개요
- **Cluster**: kubeadm 기반 Kubernetes
- **Service Mesh**: Istio 1.26.x
- **Monitoring**: Prometheus, Grafana, Kiali, Jaeger
- **Application**: Google Cloud Microservices Demo (Online Boutique)

---

## 📂 단계별 실험
### A) Gateway
- Istio IngressGateway 생성
- Online Boutique 애플리케이션의 외부 진입점 구성
- `VirtualService` 를 이용해 `shop.local` 호스트로 라우팅

👉 [A-gateway](./A-gateway)

---

### B) TLS
- Self-signed 인증서 생성 및 Secret 적용
- Gateway에 HTTPS(443) Listener 추가
- 브라우저/`curl` 로 HTTPS 접근 확인

👉 [B-tls](./B-tls)

---

### C) Rate Limit
- **Local RateLimit EnvoyFilter** 적용
- 경로별(/, /api/*) 제한 → 캡처 및 실험
- 세부 경로별(/api/cart, /api/currency) 차등 RateLimit 정책 적용
- Prometheus + Grafana 로 `429` 응답률 확인

👉 [C-rate-limit](./C-rate-limit)

---

### D) Canary (준비 중)
- Canary 배포, 오류 주입, 자동/수동 롤백 실험
- 관련 매니페스트는 `D-canary/` 디렉토리에 포함될 예정

---

## 📊 Monitoring
- Prometheus: Envoy Metrics (RateLimit, Requests, Latency)
- Grafana: 대시보드에서 HTTP Code, 429 비율 확인
- Kiali: 서비스 간 트래픽 흐름 시각화
- Jaeger: 트레이싱 및 지연 분석

---

## 👨‍💻 Contributors
- 김한식 (IT융합전공, 4학년)


