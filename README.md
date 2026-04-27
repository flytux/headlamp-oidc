# Headlamp OIDC 연동 구성

Created By: Jaehoon Jung
Created: April 28, 2026 8:08 AM
Last Edited Time: April 28, 2026 8:09 AM
Last Edited By: Jaehoon Jung

### kube-oidc-proxy와 외부 oidc IDP를 이용하여 headlamp의 클러스터 접근 권한 제어 설정

---
- 외부 IDP로 Keycloak 이용
- kube-odic-proxy 이용 API-server 역할 수행 (**Impersonate 권한 부여**)
- Headlamp kubeconfig를 kube-oidc-proxy를 대상으로 구성
- oidc 서버 제공 Group 값에 따라 k8s cluster-admin과 view 역할 부여
- Group : hl-admins > cluster-admin
- Group : hl-devs > view
---

### 1. Keycloak, Kube-oidc-proxy, headlamp 용 인증서 생성

```jsx
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout keycloak.key -out keycloak.crt -subj '/CN=keycloak.node-01' \
  -addext 'subjectAltName=DNS:keycloak.node-01,DNS:keycloak.headlamp'

openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout kube-oidc-proxy.key -out kube-oidc-proxy.crt -subj '/CN=kube-oidc-proxy.node-01' \
  -addext 'subjectAltName=DNS:kube-oidc-proxy.node-01,DNS:kube-oidc-proxy.headlamp'

openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout headlamp.key -out headlamp.crt -subj '/CN=headlamp.node-01' \
  -addext 'subjectAltName=DNS:headlamp.node-01'

kubectl create ns headlamp

kubectl create secret tls keycloak-tls --key keycloak.key --cert keycloak.crt -n headlamp
kubectl create secret tls kube-oidc-proxy-tls --key kube-oidc-proxy.key --cert kube-oidc-proxy.crt -n headlamp
kubectl create secret tls headlamp-tls --key headlamp.key --cert headlamp.crt -n headlamp
```

### 2. Keycloak 설치, Realm, 사용자, 클라이언트 생성

```jsx
# Keycloak deploy YAML
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
      - name: keycloak
        image: quay.io/keycloak/keycloak:26.6.1
        args:
        - start-dev
        - --http-enabled=true
        - --hostname=https://keycloak.node-01
        - --proxy-headers=xforwarded
        env:
        - name: KC_BOOTSTRAP_ADMIN_USERNAME
          value: admin
        - name: KC_BOOTSTRAP_ADMIN_PASSWORD
          value: admin123
        - name: KC_HEALTH_ENABLED
          value: "true"
        ports:
        - containerPort: 8080
          name: http
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 9000
          initialDelaySeconds: 30
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /health/live
            port: 9000
          initialDelaySeconds: 60
          periodSeconds: 15
        resources:
          requests:
            cpu: 250m
            memory: 768Mi
          limits:
            memory: 1536Mi
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
spec:
  selector:
    app: keycloak
  ports:
  - name: http
    port: 80
    targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - keycloak.node-01
    secretName: keycloak-tls
  rules:
  - host: keycloak.node-01
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: keycloak
            port:
              number: 80
              
              
---
# Keycloak Bootstrap Script

set -euo pipefail

: "${KEYCLOAK_NS:=headlamp}"
: "${REALM:=headlamp}"
: "${ADMIN_GROUP:=hl-admins}"
: "${DEV_GROUP:=hl-devs}"
: "${ADMIN_USER:=admin}"
: "${ADMIN_PASSWORD:=password}"
: "${DEV_USER:=dev}"
: "${DEV_PASSWORD:=password}"
: "${CLIENT_ID:=headlamp}"
: "${HEADLAMP_URL:=http://headlamp.node-01}"

KEYCLOAK_POD=$(kubectl -n "${KEYCLOAK_NS}" get pod -l app=keycloak -o jsonpath='{.items[0].metadata.name}')

kubectl -n "${KEYCLOAK_NS}" exec "${KEYCLOAK_POD}" -- /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://127.0.0.1:8080 \
  --realm master \
  --user admin \
  --password admin123 >/dev/null

kubectl -n "${KEYCLOAK_NS}" exec "${KEYCLOAK_POD}" -- /opt/keycloak/bin/kcadm.sh create realms -s realm="${REALM}" -s enabled=true || true

for group_name in "${ADMIN_GROUP}" "${DEV_GROUP}"; do
  kubectl -n "${KEYCLOAK_NS}" exec "${KEYCLOAK_POD}" -- /opt/keycloak/bin/kcadm.sh create groups -r "${REALM}" -s name="${group_name}" || true
done

create_user() {
  local username="$1"
  local password="$2"
  local group_name="$3"
  local user_id
  local group_id
  local email first_name last_name

  email="${username}@headlamp.local"
  first_name="${username}"
  last_name="user"

  kubectl -n "${KEYCLOAK_NS}" exec "${KEYCLOAK_POD}" -- /opt/keycloak/bin/kcadm.sh create users -r "${REALM}" \
    -s username="${username}" \
    -s enabled=true \
    -s emailVerified=true \
    -s email="${email}" \
    -s firstName="${first_name}" \
    -s lastName="${last_name}" || true

  user_id=$(kubectl -n "${KEYCLOAK_NS}" exec "${KEYCLOAK_POD}" -- /opt/keycloak/bin/kcadm.sh get users -r "${REALM}" -q username="${username}" --fields id --format csv --noquotes | tail -n 1)
  group_id=$(kubectl -n "${KEYCLOAK_NS}" exec "${KEYCLOAK_POD}" -- /opt/keycloak/bin/kcadm.sh get groups -r "${REALM}" --fields id,name --format csv --noquotes | awk -F, -v name="${group_name}" '$2 == name { print $1 }')

  kubectl -n "${KEYCLOAK_NS}" exec "${KEYCLOAK_POD}" -- /opt/keycloak/bin/kcadm.sh set-password -r "${REALM}" --userid "${user_id}" --new-password "${password}"
  kubectl -n "${KEYCLOAK_NS}" exec "${KEYCLOAK_POD}" -- /opt/keycloak/bin/kcadm.sh update users/"${user_id}" -r "${REALM}" \
    -s enabled=true \
    -s emailVerified=true \
    -s email="${email}" \
    -s firstName="${first_name}" \
    -s lastName="${last_name}" \
    -s 'requiredActions=[]'
  kubectl -n "${KEYCLOAK_NS}" exec "${KEYCLOAK_POD}" -- /opt/keycloak/bin/kcadm.sh update users/"${user_id}"/groups/"${group_id}" -r "${REALM}" || true
}

create_user "${ADMIN_USER}" "${ADMIN_PASSWORD}" "${ADMIN_GROUP}"
create_user "${DEV_USER}" "${DEV_PASSWORD}" "${DEV_GROUP}"

kubectl -n "${KEYCLOAK_NS}" exec "${KEYCLOAK_POD}" -- /opt/keycloak/bin/kcadm.sh create clients -r "${REALM}" \
  -s clientId="${CLIENT_ID}" \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=true \
  -s 'redirectUris=["'"${HEADLAMP_URL}"'/oidc-callback","'"${HEADLAMP_URL}"'/oauth2/callback"]' \
  -s 'webOrigins=["+"]' || true

CLIENT_UUID=$(kubectl -n "${KEYCLOAK_NS}" exec "${KEYCLOAK_POD}" -- /opt/keycloak/bin/kcadm.sh get clients -r "${REALM}" -q clientId="${CLIENT_ID}" --fields id --format csv --noquotes | tail -n 1)

kubectl -n "${KEYCLOAK_NS}" exec "${KEYCLOAK_POD}" -- /opt/keycloak/bin/kcadm.sh create clients/"${CLIENT_UUID}"/protocol-mappers/models -r "${REALM}" \
  -s name=groups \
  -s protocol=openid-connect \
  -s protocolMapper=oidc-group-membership-mapper \
  -s 'config."full.path"=false' \
  -s 'config."id.token.claim"=true' \
  -s 'config."access.token.claim"=true' \
  -s 'config."userinfo.token.claim"=true' \
  -s 'config."claim.name"=groups' || true

kubectl -n "${KEYCLOAK_NS}" exec "${KEYCLOAK_POD}" -- /opt/keycloak/bin/kcadm.sh get clients/"${CLIENT_UUID}"/client-secret -r "${REALM}"
```

### 3. Kube-oidc-proxy 설치

```jsx
# Kube-oidc-proxy YAML
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-oidc-proxy
  namespace: headlamp
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
  namespace: headlamp
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-oidc-proxy
  namespace: headlamp
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
      hostAliases:
      - ip: "192.168.222.146"
        hostnames:
        - "keycloak.node-01"
      containers:
      - name: kube-oidc-proxy
        image: ghcr.io/tremolosecurity/kube-oidc-proxy:1.0.11
        command:
        - /usr/bin/kube-oidc-proxy
        args:
        - --secure-port=8443
        - --tls-cert-file=/etc/tls/tls.crt
        - --tls-private-key-file=/etc/tls/tls.key
        - --oidc-issuer-url=https://keycloak.node-01/realms/headlamp
        - --oidc-client-id=headlamp
        - --oidc-username-claim=preferred_username
        - --oidc-groups-claim=groups
        - --oidc-ca-file=/etc/oidc/keycloak.crt
        ports:
        - containerPort: 8443
        volumeMounts:
        - name: tls
          mountPath: /etc/tls
          readOnly: true
        - name: keycloak-crt
          mountPath: /etc/oidc
          readOnly: true
      volumes:
      - name: tls
        secret:
          secretName: kube-oidc-proxy-tls
      - name: keycloak-crt
        secret:
          secretName: keycloak-crt
---
apiVersion: v1
kind: Service
metadata:
  name: kube-oidc-proxy
  namespace: headlamp
spec:
  selector:
    app: kube-oidc-proxy
  ports:
  - port: 443
    targetPort: 8443
---
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
  name: hl-admins
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
  name: hl-devs
  apiGroup: rbac.authorization.k8s.io
```

### **4. Headlamp 용 Kubeconfig 생성**

```jsx
**# Kube-oidc-proxy 인증서 base64 encoding 값을 certificate-authority-data 값에 설정**
---
apiVersion: v1
kind: Config
clusters:
  - cluster:
      certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUZTakNDQXpLZ0F3SUJBZ0lVTXQ5MVVsd3NWbFBaanFlM0FNWmVnTXRrTDBnd0RRWUpLb1pJaHZjTkFRRUwKQlFBd0lqRWdNQjRHQTFVRUF3d1hhM1ZpWlMxdmFXUmpMWEJ5YjNoNUxtNXZaR1V0TURFd0hoY05Nall3TkRJMgpNRGd6TmpJNVdoY05Nell3TkRJek1EZ3pOakk1V2pBaU1TQXdIZ1lEVlFRRERCZHJkV0psTFc5cFpHTXRjSEp2CmVIa3VibTlrWlMwd01UQ0NBaUl3RFFZSktvWklodmNOQVFFQkJRQURnZ0lQQURDQ0Fnb0NnZ0lCQUt1ajZydHUKak5FYnZvV1ZjUGxXbFZKQmI0M1g0NVI3YmV2ZjY4RGpQa21nbEJwanlQb2MzSkNVczdjV2piK0FBV2ZNTXFEVApSdFlucXJNLzQyMG4yMmU0dlFIcjlldlJFYXl5Mjh0VFRqTnRiNkZDWWsrMk02dG0rNVNiejc2b0Iwd1RyMEJkCm52djFicW5DcTNRbW5WN0cwMC9reWtKSXdPeUVLS200aFpSYmxWaHN3ZDhSbTNjVER6dFEzU09VNkZudEFadHkKRWxSdExKbnREVGhHclRiNnJJbHdWRHd5YXFOSEQxU2FhTVR3dlVVNmFGRmc0czB1dXhFdk9LVFNSQStkS3AvegpqMzczUlFyUGdTQ013SnlLMkpvY2t2M3dodFQwTlRHV0lZWUJEcFAveGxmaTBDRFB5aE1ISlp2YWtVMlBXaUtGCktwbDdQazFpeDc1M2FJTWRRc0JDMFM4ODJZczJkdzNiY0pES29tQzBUc01nVmRkNkExWTBSUDRvVjRXanlkVUQKaFR4cFlJcHU3K2R6L3FicFhwbnRURXowTDRpUVdaL2NkNWJrajI0YVppRzZVci80QU0xcFBkYVpoUndpL2lzSgo3TnkvV090UFhXcTg1VjZLRUZYWllwMDBtRHEwUDh1bndwZjgzbEJZbWZwM0ZnUjYrV1drYUJpZy82eU92SnMrCmZTUCtxaVhpcnhPZW5JN29obzljK0ZyN2t2b0l1VGtaRnMvTXZYNkVsOTM5cFVVdEowaCtGVlZkcUlFcnQ3T0QKSUZJczlSTnFZSHN3eW15clNlU0VzTEpYYlNWRmtnTTZXdS9veDIxOVE2VjV6RmFmVXU0eTM3MGVVQyt4YWJqMAphM1YzekQ3bFVNb3pDc2FaSXgvZVhMRzZ5MCtXd2hnUzZ4OGZBZ01CQUFHamVEQjJNQjBHQTFVZERnUVdCQlFXCktJeWNZRnZOdjBEVzc1WnJWa2U3VVVHMkZqQWZCZ05WSFNNRUdEQVdnQlFXS0l5Y1lGdk52MERXNzVaclZrZTcKVVVHMkZqQVBCZ05WSFJNQkFmOEVCVEFEQVFIL01DTUdBMVVkRVFRY01CcUNHR3QxWW1VdGIybGtZeTF3Y205NAplUzVvWldGa2JHRnRjREFOQmdrcWhraUc5dzBCQVFzRkFBT0NBZ0VBTkxwemFDbnEvNUUwR0twSzZpSWFaY2lHClBEMWFHM3hqT01qb2ROaXI4RWR4cThoSlpDNjNjNU1aV3JCajVvUlFRUWxrSEYwemZtWmNFS1dHeG1nUmN0ZnkKclNtNCtJWnJKMmtBZ0NlMG15dThVejlvTDNVWGNZdTU4b2ZsSHFYcTBKZmxlRkRvMUtoeG1IYzhoMkFreXVmRwpVazhMQWtha3N3TDdIazQ0NzNGV0JsaUVnaEpGSjl6cU0wdGFqdkhBeDBVOU8rbmVKa3JXTFBSVlNFVmpOaXduCkpGSzBSUFdXMmhvM1NnejRNeTZTNkk2SWhTVkJ3LzZlSzJydHdWelFveG5EZEhyaVozcmRMSHhUTU1YMml4M3oKZFlXR1oxYytCcHR5elUzZVF6dWZQVDlaK25UQ21QRVBkSFpDSkZNeExPZmZwd2NxQllKQ1ZpZFRDcFZ3Wi9QbwpzTmJzb3FlclJBb2toTE1FbXo1RXJCUDk3a3hsNERzam94SzdwdUo1NlBKa0lVNWRrUWlaalpZYU1aejdYV21MCmpEVlUrdFRUN0F2alF5dHRJSGsvM3RDcitkVVZsL3hYYW14blo2VWI4UnAzUWFvY3RNR0xpcEw4SzhUVmlIYVMKVlRuRXZyd0ZYNXFCaWZocjcrajZ3dERMeElFQ0ZFNlFlWEJDdGxiWmNqMUVGakxZRlZRU2hCdkR5Y3htMTZhZQp0TVlvMG1FcU45RTk0YUxTdXpyNEFFanZDR3BoVEgwRmppb3ZBT0syTFhudEVxWEpTN2FWL3dNeDJ2MmU2ODJPCmhFc3RGT1BnSEExekRab2Q4UTVSdU4vNHc2UDhqUnVSeGcveDAzVUZaYVAxTmFFWmR4SWRQMmprOUlXOU5KQWQKOHVEVUpiZzRVZ2Q5NzNaZno1Zz0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=
      server: https://kube-oidc-proxy.headlamp
    name: kube-oidc-proxy
contexts:
  - context:
      cluster: kube-oidc-proxy
      user: oidc
    name: kube-oidc-proxy
current-context: kube-oidc-proxy
users:
  - name: oidc
    user:
      auth-provider:
        name: oidc
        config:
          client-id: headlamp
          client-secret: 15IyYr8lTu6Rym3HELGcOK8dhqcCRhjl
          idp-issuer-url: https://keycloak.node-01/realms/headlamp
          scopes: openid profile email
          useAccessToken: "true"
---
**# 위 config 파일로 시크릿 생성

kubectl create secret generic headlamp-proxy-kubeconfig --from-file=config=kube-oidc-proxy-config -n headlamp**
```

### **5. Headlamp 설치**

```jsx
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.kubernetes.io/instance: headlamp
    app.kubernetes.io/name: headlamp
  name: headlamp
  namespace: headlamp
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/instance: headlamp
      app.kubernetes.io/name: headlamp
  template:
    metadata:
      labels:
        app.kubernetes.io/instance: headlamp
        app.kubernetes.io/name: headlamp
    spec:
      automountServiceAccountToken: true
      containers:
      - args:
        - -oidc-use-cookie
        - -plugins-dir=/headlamp/plugins
        - -session-ttl=86400
        - -oidc-client-id=$(OIDC_CLIENT_ID)
        - -oidc-client-secret=$(OIDC_CLIENT_SECRET)
        - -oidc-idp-issuer-url=$(OIDC_ISSUER_URL)
        - -oidc-scopes=$(OIDC_SCOPES)
        - -oidc-callback-url=$(OIDC_CALLBACK_URL)
        - -oidc-validator-client-id=$(OIDC_VALIDATOR_CLIENT_ID)
        - -oidc-validator-idp-issuer-url=$(OIDC_VALIDATOR_ISSUER_URL)
        - -kubeconfig=/etc/headlamp/kubeconfig/config
        env:
        - name: OIDC_CLIENT_ID
          valueFrom:
            secretKeyRef:
              key: clientID
              name: oidc
        - name: OIDC_CLIENT_SECRET
          valueFrom:
            secretKeyRef:
              key: clientSecret
              name: oidc
        - name: OIDC_ISSUER_URL
          valueFrom:
            secretKeyRef:
              key: issuerURL
              name: oidc
        - name: OIDC_SCOPES
          valueFrom:
            secretKeyRef:
              key: scopes
              name: oidc
        - name: OIDC_CALLBACK_URL
          valueFrom:
            secretKeyRef:
              key: callbackURL
              name: oidc
        - name: OIDC_VALIDATOR_CLIENT_ID
          valueFrom:
            secretKeyRef:
              key: validatorClientID
              name: oidc
        - name: OIDC_VALIDATOR_ISSUER_URL
          valueFrom:
            secretKeyRef:
              key: validatorIssuerURL
              name: oidc
        - name: SSL_CERT_FILE
          value: /etc/headlamp-oidc/keycloak.crt
        image: ghcr.io/headlamp-k8s/headlamp:v0.41.0
        imagePullPolicy: IfNotPresent
        livenessProbe:
          failureThreshold: 3
          httpGet:
            path: /
            port: http
            scheme: HTTP
          periodSeconds: 10
          successThreshold: 1
          timeoutSeconds: 1
        name: headlamp
        ports:
        - containerPort: 4466
          name: http
          protocol: TCP
        readinessProbe:
          failureThreshold: 3
          httpGet:
            path: /
            port: http
            scheme: HTTP
          periodSeconds: 10
          successThreshold: 1
          timeoutSeconds: 1
        resources: {}
        securityContext:
          privileged: false
          runAsGroup: 101
          runAsNonRoot: true
          runAsUser: 100
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        volumeMounts:
        - mountPath: /etc/headlamp/kubeconfig
          name: kubeconfig
        - mountPath: /etc/headlamp-oidc
          name: oidc-ca
      dnsPolicy: ClusterFirst
      hostAliases:
      - hostnames:
        - keycloak.node-01
        ip: 192.168.222.146
      hostUsers: true
      restartPolicy: Always
      serviceAccount: headlamp
      serviceAccountName: headlamp
      volumes:
      - name: kubeconfig
        secret:
          defaultMode: 420
          secretName: headlamp-proxy-kubeconfig
      - name: oidc-ca
        secret:
          defaultMode: 420
          secretName: keycloak-crt
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/instance: headlamp
    app.kubernetes.io/name: headlamp
  name: headlamp
  namespace: headlamp
spec:
  ports:
  - name: http
    port: 80
    protocol: TCP
    targetPort: http
  selector:
    app.kubernetes.io/instance: headlamp
    app.kubernetes.io/name: headlamp
  sessionAffinity: None
  type: ClusterIP
---
apiVersion: v1
kind: Secret
metadata:
  name: oidc
  namespace: headlamp
data:
  # http://headlamp.node-01/oidc-callback
  callbackURL: aHR0cDovL2hlYWRsYW1wLm5vZGUtMDEvb2lkYy1jYWxsYmFjaw==
  # headlamp
  clientID: aGVhZGxhbXA=
  # Keycloak 확인값
  clientSecret: UWlWNmxNYlBFQ1hlbjh5bmJCZm1FZ1lOWlNpNnhFYks=
  # https://keycloak.node-01/realms/headlamp
  issuerURL: aHR0cHM6Ly9rZXljbG9hay5ub2RlLTAxL3JlYWxtcy9oZWFkbGFtcA==
  # openid profile email
  scopes: b3BlbmlkIHByb2ZpbGUgZW1haWwgb2ZmbGluZV9hY2Nlc3M=
  # headlamp
  validatorClientID: aGVhZGxhbXA=
  # https://keycloak.node-01/realms/headlamp
  validatorIssuerURL: aHR0cHM6Ly9rZXljbG9hay5ub2RlLTAxL3JlYWxtcy9oZWFkbGFtcA==
type: Opaque
```

### **6. Keycloak, Headlamp 로그인**

```jsx
# http://keyclaok.node-01
# http://headlamp.node-01

- admin / password
- dev / password
```
