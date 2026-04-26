# Keycloak + OIDC Proxy (oauth2-proxy / kube-oidc-proxy) + Headlamp

> **구성 방식**
> - **[인증 + 단일 권한]** (1~10) : oauth2-proxy로 UI 접근 보호 + 공용 SA 토큰으로 자동 로그인 (간단, 단일 권한)
> - **[그룹별 RBAC 적용]** (11~)  : headlamp oidc 이용 - kube-oidc-proxy 로 그룹별 RBAC 자동 적용 (kube-apiserver 설정 변경 불필요)

## 아키텍처

```
Browser → nginx Ingress → Headlamp (Keycloak OIDC 로그인)
                              ↓ Bearer <access_token>
                         kube-oidc-proxy (TremoloSecurity)
                           - Keycloak 토큰 검증
                           - groups 클레임 추출
                           ↓ Impersonate-User / Impersonate-Group
                         kube-apiserver → RBAC
                           - headlamp-admins → cluster-admin
                           - headlamp-devs   → view
```

## 1. 변수

```bash
export KEYCLOAK_HOST="keycloak.node-01"
export HEADLAMP_HOST="headlamp.node-01"
export KEYCLOAK_NS="keycloak"
export HEADLAMP_NS="headlamp"

export KC_ADMIN_USER="admin"
export KC_ADMIN_PASSWORD="admin123"

export REALM="headlamp"
export GROUP_NAME="hl-admin"
export DEV_GROUP_NAME="hl-dev"
export USERNAME="hl-user"
export USER_PASSWORD="hl-password"

export CLIENT_ID="headlamp"
export REDIRECT_URI="http://${HEADLAMP_HOST}/oauth2/callback"
```

## 2. Helm repo
```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update
```

## 3. Keycloak 설치

```bash
kubectl create namespace ${KEYCLOAK_NS} --dry-run=client -o yaml | kubectl apply -f -
cat > keycloak-values.yaml <<EOF
auth:
  adminUser: ${KC_ADMIN_USER}
  adminPassword: ${KC_ADMIN_PASSWORD}
ingress:
  enabled: true
  ingressClassName: nginx
  hostname: ${KEYCLOAK_HOST}
  tls: false
postgresql:
  enabled: true
production: true
proxy: edge
EOF

helm upgrade --install keycloak bitnami/keycloak \
  -n ${KEYCLOAK_NS} \
  -f keycloak-values.yaml

kubectl -n ${KEYCLOAK_NS} rollout status deploy/keycloak --timeout=5m
```

## 4. Keycloak 초기 설정

```bash
export KEYCLOAK_POD=$(kubectl -n ${KEYCLOAK_NS} get pod -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}')

kubectl -n ${KEYCLOAK_NS} exec -i ${KEYCLOAK_POD} -- \
  env REALM="${REALM}" \
      GROUP_NAME="${GROUP_NAME}" \
      USERNAME="${USERNAME}" \
      USER_PASSWORD="${USER_PASSWORD}" \
      CLIENT_ID="${CLIENT_ID}" \
      REDIRECT_URI="${REDIRECT_URI}" \
      KC_ADMIN_USER="${KC_ADMIN_USER}" \
      KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD}" \
      bash < scripts/keycloak-bootstrap.sh
```

## 5. Keycloak - headlamp-devs 그룹 추가 및 groups mapper 확인

> **주의**: 1단계 변수가 모두 export 되어 있어야 합니다. 새 터미널이면 1단계 전체를 다시 실행하세요.

```bash
export KEYCLOAK_POD=$(kubectl -n ${KEYCLOAK_NS} get pod -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}')

kubectl -n ${KEYCLOAK_NS} exec -i ${KEYCLOAK_POD} -- \
  env REALM="${REALM}" DEV_GROUP_NAME="${DEV_GROUP_NAME}" \
      CLIENT_ID="${CLIENT_ID}" \
      KC_ADMIN_USER="${KC_ADMIN_USER}" KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD}" \
  bash -s <<'EOF'
export HOME=/tmp; export KCADM_CONFIG=/tmp/kcadm.config
KC=/opt/bitnami/keycloak/bin/kcadm.sh
$KC config credentials --server http://127.0.0.1:8080 --realm master \
  --user "$KC_ADMIN_USER" --password "$KC_ADMIN_PASSWORD"

# hl-dev 그룹 생성
$KC create groups -r "$REALM" -s name="$DEV_GROUP_NAME" || true

CLIENT_UUID=$($KC get clients -r "$REALM" -q clientId="$CLIENT_ID" \
  | tr -d '\n' \
  | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 | cut -d'"' -f4)

# groups mapper 중복 방지 후 추가
MAPPER_EXISTS=$($KC get clients/"$CLIENT_UUID"/protocol-mappers/models -r "$REALM" \
  | grep -c '"name".*:.*"groups"' || true)
if [[ "$MAPPER_EXISTS" -eq 0 ]]; then
  $KC create clients/"$CLIENT_UUID"/protocol-mappers/models -r "$REALM" \
    -s name=groups \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."full.path"=false' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true' \
    -s 'config."claim.name"=groups'
  echo "groups mapper added"
else
  echo "groups mapper already exists"
fi

# Headlamp OIDC callback URI 추가
REDIRECT_URIS=$(cat <<ENDJSON
["http://headlamp.node-01/oauth2/callback","http://headlamp.node-01/oidc-callback"]
ENDJSON
)
$KC update clients/"$CLIENT_UUID" -r "$REALM" -s "redirectUris=${REDIRECT_URIS}"
echo "Done"
EOF
```

## 6. kube-oidc-proxy TLS 인증서

```bash
export KEYCLOAK_SVC_IP=$(kubectl -n ${KEYCLOAK_NS} get svc keycloak -o jsonpath='{.spec.clusterIP}')

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /tmp/oidc-proxy-key.pem \
  -out /tmp/oidc-proxy-cert.pem \
  -days 365 \
  -subj "/CN=kube-oidc-proxy.${HEADLAMP_NS}.svc" \
  -addext "subjectAltName=DNS:kube-oidc-proxy.${HEADLAMP_NS}.svc,DNS:kube-oidc-proxy.${HEADLAMP_NS}.svc.cluster.local"

kubectl -n ${HEADLAMP_NS} create secret tls kube-oidc-proxy-tls \
  --cert=/tmp/oidc-proxy-cert.pem \
  --key=/tmp/oidc-proxy-key.pem \
  --dry-run=client -o yaml | kubectl apply -f -
```

## 7. kube-oidc-proxy RBAC

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-oidc-proxy
  namespace: ${HEADLAMP_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-oidc-proxy
rules:
- apiGroups: [""]
  resources: ["users", "groups", "serviceaccounts"]
  verbs: ["impersonate"]
- apiGroups: ["authentication.k8s.io"]
  resources: ["userextras", "userextras/authentication.kubernetes.io/credential-id", "uids"]
  verbs: ["impersonate"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-oidc-proxy
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-oidc-proxy
subjects:
- kind: ServiceAccount
  name: kube-oidc-proxy
  namespace: ${HEADLAMP_NS}
EOF
```

## 8. kube-oidc-proxy Deployment + Service

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-oidc-proxy
  namespace: ${HEADLAMP_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kube-oidc-proxy
  template:
    metadata:
      labels:
        app: kube-oidc-proxy
    spec:
      serviceAccountName: kube-oidc-proxy
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
      hostAliases:
      - ip: "${KEYCLOAK_SVC_IP}"
        hostnames:
        - "keycloak.node-01"
      containers:
      - name: kube-oidc-proxy
        image: ghcr.io/tremolosecurity/kube-oidc-proxy:1.0.11
        command:
        - /usr/bin/kube-oidc-proxy
        ports:
        - containerPort: 8443
        args:
        - --secure-port=8443
        - --tls-cert-file=/etc/tls/tls.crt
        - --tls-private-key-file=/etc/tls/tls.key
        - --oidc-issuer-url=http://keycloak.node-01/realms/${REALM}
        - --oidc-client-id=${CLIENT_ID}
        - --oidc-username-claim=preferred_username
        - --oidc-groups-claim=groups
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: tls
          mountPath: /etc/tls
          readOnly: true
      volumes:
      - name: tls
        secret:
          secretName: kube-oidc-proxy-tls
---
apiVersion: v1
kind: Service
metadata:
  name: kube-oidc-proxy
  namespace: ${HEADLAMP_NS}
spec:
  selector:
    app: kube-oidc-proxy
  ports:
  - port: 443
    targetPort: 8443
EOF

kubectl -n ${HEADLAMP_NS} rollout status deploy/kube-oidc-proxy --timeout=2m
```

## 9. 그룹별 ClusterRoleBinding

```bash
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-headlamp-admins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: Group
  name: headlamp-admins
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-headlamp-devs
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
- kind: Group
  name: headlamp-devs
  apiGroup: rbac.authorization.k8s.io
EOF
```

## 10. Headlamp - OIDC 모드 + kube-oidc-proxy kubeconfig

```bash

# kube-oidc-proxy TLS CA 추출
CA=$(kubectl -n ${HEADLAMP_NS} get secret kube-oidc-proxy-tls \
  -o jsonpath='{.data.tls\.crt}')

# kubeconfig Secret 생성 (server = kube-oidc-proxy)
kubectl -n ${HEADLAMP_NS} create secret generic headlamp-proxy-kubeconfig \
  --from-literal=config="apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA}
    server: https://kube-oidc-proxy.${HEADLAMP_NS}.svc
  name: kube-oidc-proxy
contexts:
- context:
    cluster: kube-oidc-proxy
    user: oidc
  name: kube-oidc-proxy
current-context: kube-oidc-proxy
users:
- name: oidc
  user: {}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Headlamp 재배포 (OIDC 모드)
helm upgrade headlamp headlamp/headlamp -n ${HEADLAMP_NS} -f - <<EOF
service:
  type: ClusterIP
ingress:
  enabled: false
config:
  oidc:
    clientID: ${CLIENT_ID}
    clientSecret: ${OAUTH2_PROXY_CLIENT_SECRET}
    issuerURL: http://keycloak.node-01/realms/${REALM}
    scopes: "openid profile email"
extraArgs:
  - -kubeconfig=/etc/headlamp/kubeconfig/config
extraVolumes:
  - name: kubeconfig
    secret:
      secretName: headlamp-proxy-kubeconfig
extraVolumeMounts:
  - name: kubeconfig
    mountPath: /etc/headlamp/kubeconfig
    readOnly: true
hostAliases:
  - ip: "${KEYCLOAK_SVC_IP}"
    hostnames:
      - "keycloak.node-01"
EOF
```

## 11. Ingress (oauth2-proxy 없이 단순 구성)

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: headlamp
  namespace: ${HEADLAMP_NS}
spec:
  ingressClassName: nginx
  rules:
  - host: ${HEADLAMP_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: headlamp
            port:
              number: 80
EOF
```

## 12. 동작 확인

```bash
# 파드 상태
kubectl get pods -n ${HEADLAMP_NS}

# kube-oidc-proxy 로그 (정상: 인증 성공 로그)
kubectl -n ${HEADLAMP_NS} logs -l app=kube-oidc-proxy --tail=20

# 브라우저 접속
echo http://${HEADLAMP_HOST}
```

정상 흐름:

1. `http://headlamp.node-01` 접속
2. Headlamp가 Keycloak으로 리다이렉트 → 로그인
3. Headlamp가 access token으로 kube-oidc-proxy에 API 요청
4. kube-oidc-proxy 로그: `AuSuccess ... inbound:[headlamp-user / headlamp-admins|...]`
5. RBAC 적용 → 그룹별 권한으로 자동 접속 (토큰 입력 없음)


## 그룹별 접근 테스트

```bash
# hl-admin 멤버로 로그인 → cluster-admin 권한 (모든 리소스 보임)
# hl-dev 멤버로 로그인   → view 권한 (읽기만 가능)

모두 정상 동작

# kube-oidc-proxy 로그에서 그룹 확인
kubectl -n ${HEADLAMP_NS} logs -l app=kube-oidc-proxy --tail=5 | grep AuSuccess
```
