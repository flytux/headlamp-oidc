### Keycloak / Kube-OIDC-Proxy / Headlamp

---
#### 1) 소프트웨어
```
1) k8s 클러스터

2) Keycloak (OIDC 제공자)

3) kube-oidc-proxy (API 인증 프록시)

4) Headlamp (UI)
```
---

#### 2) helm 설정

```
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo add jetstack https://charts.jetstack.io
helm repo update
```

#### 3) Keycloak 설치

- Bitnami chart 사용

```
kubectl patch storageclass nfs-csi -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'


kubectl create ns keycloak

helm upgrade -i keycloak bitnami/keycloak \
  -n keycloak \
  --set auth.adminUser=admin \
  --set auth.adminPassword=admin123 \
  --set image.repository=bitnamilegacy/keycloak \
  --set postgresql.image.repository=bitnamilegacy/postgresql \
  --set ingress.enabled=true \
  --set ingress.ingressClassName=nginx \
  --set ingress.hostname=keycloak.node-01
```



- 접속: http://keycloak.node-01
- Keycloak 설정
```
#로그인
admin / admin123

#Realm 생성
이름: k8s

#Client 생성
Client ID: headlamp
Client Type: OpenID Connect

#설정
Valid Redirect URI:
http://localhost:4466/oidc-callback

#사용자 생성
username: k8s-admin
password: password

#그룹 생성
그룹: k8s-admin
사용자에 그룹 추가

#groups claim 추가
Client scopes > Create Client scopes > 이름지정 > Type Default
Mappers > Predefined Mappers > groups
Client → Mappers → Create:
Name: groups
Mapper Type: Group Membership
Token Claim Name: groups
Full group path: OFF
```
---
5️⃣ kube-oidc-proxy 설치
kubectl create ns oidc

helm repo add jetstack https://charts.jetstack.io
helm repo update
👉 (공식 chart 없어서 values 기반으로 구성)

values.yaml 생성
cat <<EOF > oidc-values.yaml
extraArgs:
  - --oidc-issuer-url=http://<NODE-IP>:<KEYCLOAK-PORT>/realms/k8s
  - --oidc-client-id=headlamp
  - --oidc-username-claim=preferred_username
  - --oidc-groups-claim=groups
  - --insecure-skip-tls-verify=true

service:
  type: NodePort
EOF
설치:

helm install oidc-proxy jetstack/kube-oidc-proxy \
  -n oidc \
  -f oidc-values.yaml
6️⃣ RBAC (핵심 ⚠️)
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: oidc-proxy
rules:
- apiGroups: [""]
  resources: ["users","groups"]
  verbs: ["impersonate"]
EOF
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-proxy-binding
subjects:
- kind: ServiceAccount
  name: default
  namespace: oidc
roleRef:
  kind: ClusterRole
  name: oidc-proxy
  apiGroup: rbac.authorization.k8s.io
EOF
7️⃣ Keycloak 그룹 → Kubernetes 권한 연결
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: k8s-admin-binding
subjects:
- kind: Group
  name: k8s-admin
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF
8️⃣ Headlamp 설치
kubectl create ns headlamp

helm install headlamp headlamp/headlamp \
  -n headlamp \
  --set service.type=NodePort
9️⃣ Headlamp OIDC 설정
Headlamp config 수정:

kubectl edit cm headlamp-config -n headlamp
추가:

oidc:
  clientID: headlamp
  issuerURL: http://<NODE-IP>:<KEYCLOAK-PORT>/realms/k8s
🔟 접속 및 테스트
10-1 Headlamp 접속
kubectl get svc -n headlamp
👉 브라우저 접속:

http://<NODE-IP>:<HEADLAMP-PORT>
10-2 로그인 흐름
Headlamp → Keycloak redirect

testuser 로그인

토큰 발급

kube-oidc-proxy 전달

kube-apiserver 접근

🔥 트러블슈팅 핵심
❌ 로그인 되는데 권한 없음
👉 대부분 groups claim 문제

확인:

kubectl auth can-i get pods --as=testuser
❌ 401 Unauthorized
👉 issuer URL mismatch

❌ redirect error
👉 Keycloak redirect URI 정확히 맞춰야 함

✔️ 완성 상태
이제:

Keycloak 로그인

Headlamp 접근

RBAC 기반 권한 제어

모두 정상 동작

💡 현실적인 개선 (강력 추천)
지금 구성은 테스트용입니다. 운영에서는 반드시:

HTTPS (Ingress + cert-manager)

Keycloak 외부 DNS

kube-oidc-proxy TLS

ServiceAccount 분리

원하면 다음 단계도 바로 만들어드릴게요:

ingress + cert-manager 포함 “실운영 YAML”

docker-compose Keycloak 대신 helm production 설정

GitOps (ArgoCD)로 자동 배포 구조