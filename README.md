# Online Boutique + Istio Graduation Project

Google **Online Boutique** 샘플 애플리케이션을 기반으로 **Istio Service Mesh 1.26.x**의 핵심 기능을 단계별(A~E)로 실험·검증한 졸업 작품 저장소입니다.  
게이트웨이/TLS, JWT 인증·인가, 로컬 레이트리밋, 카나리 배포+오류주입, 아웃라이어 감지(자동 퇴출)까지 **운영 시나리오**를 실제 트래픽/대시보드로 확인할 수 있습니다.
[노션 링크](https://www.notion.so/21b808fc218d80868d48cb2c7331defc?source=copy_link)
---

## 목차
- [환경 개요](#환경-개요)
- [폴더 구조](#폴더-구조)
- [요구 사항](#요구-사항)
- [빠른 시작(Quick Start)](#빠른-시작quick-start)
- [단계별 요약](#단계별-요약)
- [모니터링 & 관찰 포인트](#모니터링--관찰-포인트)
- [유용한 스크립트](#유용한-스크립트)
- [트러블슈팅 체크리스트](#트러블슈팅-체크리스트)
- [기여자](#기여자)
- [라이선스](#라이선스)

---

## 환경 개요
- **Cluster**: kubeadm 기반 Kubernetes  
- **Service Mesh**: Istio **1.26.x**  
- **Monitoring/Obs.**: Prometheus, Grafana, Kiali, Jaeger  
- **Application**: Google Cloud Microservices Demo (**Online Boutique**)  
- **도메인 예시**: `shop.local` (개발용, `/etc/hosts` 매핑)

---

## 폴더 구조
```
.
├─ A-gateway/        # IngressGateway + HTTPS 종단, HTTP→HTTPS 리다이렉트
├─ B-tls/            # JWT 인증/인가 (RequestAuthentication + AuthorizationPolicy)
├─ C-rate-limit/     # Local Rate Limit (EnvoyFilter)
├─ D-canary/         # Canary 트래픽 분할 + Fault Injection + 롤백 가드
├─ E-lb-outlier/     # LB 전략 + Outlier Detection(자동 퇴출) + httpbin 데모
└─ README.md         # (현재 문서) 프로젝트 개요
```
각 폴더에는 **해당 단계 전용 `README.md`**와 예시 매니페스트/스크립트가 포함됩니다.

---

## 요구 사항
- kubectl, istioctl, helm (옵션), jq, curl  
- Kubernetes 클러스터 접근 권한 (kubeadm 또는 다른 배포도 무방)  
- 사이드카 주입: 대상 네임스페이스에 `istio-injection=enabled` 라벨  
- (옵션) 로컬 테스트 시 `/etc/hosts`에 `shop.local` → Ingress IP/포트 매핑

---

## 빠른 시작(Quick Start)

['_archive'](./_archive) 의 [run_basic_setting.sh](run_basic_setting.sh) 실행

3) **각 단계 적용**  
- 게이트웨이/TLS → [`A-gateway/`](./A-gateway)  
- JWT 인증/인가 → [`B-tls/`](./B-tls)  
- 로컬 레이트리밋 → [`C-rate-limit/`](./C-rate-limit)  
- 카나리+Fault → [`D-canary/`](./D-canary)  
- 아웃라이어 감지 → [`E-lb-outlier/`](./E-lb-outlier)

---

## 단계별 요약
### A) Gateway — HTTP→HTTPS 리다이렉트 + TLS 종단
- **목적**: 외부 진입점에서 HTTPS 종단, HTTP 요청은 HTTPS로 리다이렉트  
- **리소스**: `Gateway(boutique-gw)`, `VirtualService(boutique-vs)`, Secret `shop-credential`  
- **검증**: `curl -I http://shop.local` → 301/302, `curl -skI https://shop.local:8443` → 200  
→ 상세: [`A-gateway/`](./A-gateway)

### B) JWT 인증/인가 — RequestAuthentication + AuthorizationPolicy
- **목적**: **JWT 없으면 403**, **JWT 있으면 200** (헬스체크 경로는 무토큰 허용)  
- **리소스**: `RequestAuthentication`, `AuthorizationPolicy`  
- **검증**:  
  - `curl -skI https://shop.local:8443` → 403  
  - `curl -skI https://shop.local:8443 -H "Authorization: Bearer $TOKEN"` → 200  
→ 상세: [`B-tls/`](./B-tls)

### C) Local Rate Limit — EnvoyFilter
- **목적**: `app=frontend` **Inbound** QPS 제한(**20 RPS/Pod**), 초과 시 **429**  
- **리소스**: `EnvoyFilter`(HCM `router` 앞 `envoy.filters.http.local_ratelimit`)  
- **관찰**: 429 비율, 토큰 파라미터(max_tokens/tokens_per_fill) 변경 효과  
→ 상세: [`C-rate-limit/`](./C-rate-limit)

### D) Canary + Fault Injection + 롤백 가드
- **목적**: v2로 **일부 트래픽 분배**(가중치), **헤더 기반 Fault**로 테스트 트래픽에만 Delay/Abort 주입  
- **가드 예시**: **에러율 > 2%** 또는 **p95 > 300ms** ⇒ 즉시 롤백(v1=100/v2=0)  
- **리소스**: `VirtualService`(traffic split + fault), `DestinationRule`(subsets)  
→ 상세: [`D-canary/`](./D-canary)

### E) LB 전략 + Outlier Detection(자동 퇴출)
- **목적**: 불량 인스턴스를 **자동 격리(Ejection)**, 정상 인스턴스로만 라우팅  
- **리소스**: `DestinationRule.trafficPolicy` (`loadBalancer`, `outlierDetection`)  
- **데모**: `httpbin` v1(200)/v2(500) → v2 **자동 퇴출** 검증 스크립트 포함  
→ 상세: [`E-lb-outlier/`](./E-lb-outlier)

---

## 모니터링 & 관찰 포인트
- **Grafana**: HTTP 코드 분포, 4xx/5xx RPS, 에러율(%), p95 지연  
- **Kiali**: 서비스 그래프(트래픽 애니메이션/지연/비율), 각 서비스의 **Traffic Policies**(DR/VS 인식)  
- **Jaeger**: 요청 트레이스(지연/에러 스팬), 헤더 기반 Fault 시각화  
- **Prometheus**: 라벨 구조(`destination_service` vs `destination_service_name/namespace`)를 먼저 확인하고 쿼리 작성
---

## 기여자
- **김한식** (IT융합전공, 4학년)

---

## 라이선스
- Online Boutique 및 예시 매니페스트는 각 프로젝트의 라이선스를 따릅니다.  
- 본 문서/스크립트는 교육·연구 목적 사용을 권장합니다.
