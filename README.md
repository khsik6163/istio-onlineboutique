Online Boutique + Istio Graduation Project

Google Online Boutique 샘플 애플리케이션을 기반으로 Istio Service Mesh 1.26.x의 핵심 기능을 단계별(A~E)로 실험·검증한 졸업 작품 저장소입니다.
게이트웨이/TLS, JWT 인증·인가, 로컬 레이트리밋, 카나리 배포+오류주입, 아웃라이어 감지(자동 퇴출)까지 운영 시나리오를 실제 트래픽/대시보드로 확인할 수 있습니다.

목차

환경 개요

폴더 구조

요구 사항

빠른 시작(Quick Start)

단계별 요약

모니터링 & 관찰 포인트

유용한 스크립트

트러블슈팅 체크리스트

기여자

라이선스

환경 개요

Cluster: kubeadm 기반 Kubernetes

Service Mesh: Istio 1.26.x

Monitoring/Obs.: Prometheus, Grafana, Kiali, Jaeger

Application: Google Cloud Microservices Demo (Online Boutique)

도메인 예시: shop.local (개발용, /etc/hosts 매핑)

폴더 구조
.
├─ A-gateway/        # IngressGateway + HTTPS 종단, HTTP→HTTPS 리다이렉트
├─ B-tls/            # JWT 인증/인가 (RequestAuthentication + AuthorizationPolicy)
├─ C-rate-limit/     # Local Rate Limit (EnvoyFilter)
├─ D-canary/         # Canary 트래픽 분할 + Fault Injection + 롤백 가드
├─ E-lb-outlier/     # LB 전략 + Outlier Detection(자동 퇴출) + httpbin 데모
└─ README.md         # (현재 문서) 프로젝트 개요


각 폴더에는 **해당 단계 전용 README.md**와 예시 매니페스트/스크립트가 포함됩니다.

요구 사항

kubectl, istioctl, helm (옵션), jq, curl

Kubernetes 클러스터 접근 권한 (kubeadm 또는 다른 배포도 무방)

사이드카 주입: 대상 네임스페이스에 istio-injection=enabled 라벨

(옵션) 로컬 테스트 시 /etc/hosts에 shop.local → Ingress IP/포트 매핑

빠른 시작(Quick Start)

이미 클러스터/Istio/Addons가 준비되어 있다는 가정. (없다면 각 단계 README의 “사전 준비”를 참고)

애드온 포트포워딩

kubectl -n istio-system port-forward svc/prometheus 9090:9090 &
kubectl -n istio-system port-forward svc/grafana    3000:3000 &
kubectl -n istio-system port-forward svc/kiali      20001:20001 &
kubectl -n istio-system port-forward svc/tracing    16686:80 &
# Grafana: http://localhost:3000  / Kiali: http://localhost:20001 / Jaeger: http://localhost:16686/jaeger


Online Boutique 배포 (예: boutique 네임스페이스)

kubectl create ns boutique || true
kubectl label ns boutique istio-injection=enabled --overwrite
kubectl -n boutique apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml
kubectl -n boutique rollout status deploy/frontend --timeout=300s


각 단계 적용

게이트웨이/TLS → A-gateway/

JWT 인증/인가 → B-tls/

로컬 레이트리밋 → C-rate-limit/

카나리+Fault → D-canary/

아웃라이어 감지 → E-lb-outlier/

단계별 요약
A) Gateway — HTTP→HTTPS 리다이렉트 + TLS 종단

목적: 외부 진입점에서 HTTPS 종단, HTTP 요청은 HTTPS로 리다이렉트

리소스: Gateway(boutique-gw), VirtualService(boutique-vs), Secret shop-credential

검증: curl -I http://shop.local → 301/302, curl -skI https://shop.local:8443 → 200
→ 상세: A-gateway/

B) JWT 인증/인가 — RequestAuthentication + AuthorizationPolicy

목적: JWT 없으면 403, JWT 있으면 200 (헬스체크 경로는 무토큰 허용)

리소스: RequestAuthentication, AuthorizationPolicy

검증:

curl -skI https://shop.local:8443 → 403

curl -skI https://shop.local:8443 -H "Authorization: Bearer $TOKEN" → 200
→ 상세: B-tls/

C) Local Rate Limit — EnvoyFilter

목적: app=frontend Inbound QPS 제한(20 RPS/Pod), 초과 시 429

리소스: EnvoyFilter(HCM router 앞 envoy.filters.http.local_ratelimit)

관찰: 429 비율, 토큰 파라미터(max_tokens/tokens_per_fill) 변경 효과
→ 상세: C-rate-limit/

D) Canary + Fault Injection + 롤백 가드

목적: v2로 일부 트래픽 분배(가중치), 헤더 기반 Fault로 테스트 트래픽에만 Delay/Abort 주입

가드 예시: 에러율 > 2% 또는 p95 > 300ms ⇒ 즉시 롤백(v1=100/v2=0)

리소스: VirtualService(traffic split + fault), DestinationRule(subsets)
→ 상세: D-canary/

E) LB 전략 + Outlier Detection(자동 퇴출)

목적: 불량 인스턴스를 자동 격리(Ejection), 정상 인스턴스로만 라우팅

리소스: DestinationRule.trafficPolicy (loadBalancer, outlierDetection)

데모: httpbin v1(200)/v2(500) → v2 자동 퇴출 검증 스크립트 포함
→ 상세: E-lb-outlier/

모니터링 & 관찰 포인트

Grafana: HTTP 코드 분포, 4xx/5xx RPS, 에러율(%), p95 지연

Kiali: 서비스 그래프(트래픽 애니메이션/지연/비율), 각 서비스의 Traffic Policies(DR/VS 인식)

Jaeger: 요청 트레이스(지연/에러 스팬), 헤더 기반 Fault 시각화

Prometheus: 라벨 구조(destination_service vs destination_service_name/namespace)를 먼저 확인하고 쿼리 작성

라벨 확인 팁 (Explore/Instant):
label_values(istio_requests_total, destination_service)
label_values(istio_requests_total, destination_service_name)
label_values(istio_requests_total, destination_workload)

유용한 스크립트

아웃라이어 자동 퇴출 검증: E-lb-outlier/verify-outlier.sh

v2에 에러 트래픽 집중 → Envoy Admin JSON에서 subset=v2 활성 호스트=0 판정 → PASS/FAIL 출력

(옵션) Makefile 타겟으로 검증/재시작/정리 등을 구성하면 CI에도 쉽게 연결 가능

트러블슈팅 체크리스트

 사이드카 주입: 대상 Pod에 istio-proxy 컨테이너 존재

 DNS/hosts: shop.local이 Ingress IP/포트로 정확히 연결

 TLS Secret 네임스페이스: istio-system에 shop-credential 생성

 JWT 필드: issuer, audience, jwksUri 일치

 EnvoyFilter 매칭: HCM 단계/Route 이름(vhost/routeName) 정확 매칭

 카나리 Fault: 헤더 기반 매치(테스트 트래픽만 영향), retries: { attempts: 0 }

 Outlier 확인:

istioctl pc clusters/endpoints는 subset 클러스터명으로 조회

Grafana는 라벨 구조에 맞춰 PromQL 수정(destination_service ↔ destination_service_name/namespace)

기여자

김한식 (IT융합전공, 4학년)

라이선스

Online Boutique 및 예시 매니페스트는 각 프로젝트의 라이선스를 따릅니다.

본 문서/스크립트는 교육·연구 목적 사용을 권장합니다.

참고: 각 단계의 세부 매니페스트/스크립트/PromQL은 각 폴더의 README를 확인하세요.
