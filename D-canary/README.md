# D-canary (Istio 카나리 + 오류 주입 + 롤백)

## 전제
- A 단계의 Gateway/VS(boutique-gw, shop.local)가 적용되어 있음
- C 단계(레이트리밋) EnvoyFilter들은 **비활성** 상태

## 설치
```bash
kubectl apply -f D-canary/01-frontend-v2.yaml
kubectl apply -f D-canary/10-destinationrule-frontend.yaml
kubectl apply -f D-canary/20-virtualservice-canary.yaml

