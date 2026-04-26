#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

headlamp_ns="headlamp"

kubectl -n keycloak exec deploy/keycloak -- /opt/keycloak/bin/kcadm.sh \
  config credentials --server http://127.0.0.1:8080 --realm master \
  --user admin --password admin123 >/dev/null 2>&1

client_uuid=$(kubectl -n keycloak exec deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get clients -r headlamp -q clientId=headlamp \
  --fields id --format csv --noquotes | tail -n 1)

client_secret=$(kubectl -n keycloak exec deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get clients/"${client_uuid}"/client-secret -r headlamp \
  | grep -o '"value" : "[^"]*"' | cut -d '"' -f4)

proxy_ca=$(kubectl -n "${headlamp_ns}" get secret kube-oidc-proxy-tls -o jsonpath='{.data.tls\.crt}')
ingress_ip=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')

cat >/tmp/headlamp-kubeconfig.yaml <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${proxy_ca}
    server: https://kube-oidc-proxy.${headlamp_ns}.svc
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
        client-secret: ${client_secret}
        idp-issuer-url: https://keycloak.node-01/realms/headlamp
        scopes: openid profile email offline_access
EOF

kubectl -n "${headlamp_ns}" create secret generic headlamp-proxy-kubeconfig \
  --from-file=config=/tmp/headlamp-kubeconfig.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

cat >/tmp/headlamp-values.yaml <<EOF
clusterRoleBinding:
  create: false
service:
  type: ClusterIP
config:
  oidc:
    clientID: headlamp
    clientSecret: ${client_secret}
    issuerURL: https://keycloak.node-01/realms/headlamp
    callbackURL: http://headlamp.node-01/oidc-callback
    validatorClientID: headlamp
    validatorIssuerURL: https://keycloak.node-01/realms/headlamp
    useAccessToken: false
    useCookie: true
    scopes: openid profile email offline_access
  extraArgs:
    - -kubeconfig=/etc/headlamp/kubeconfig/config
env:
  - name: SSL_CERT_FILE
    value: /etc/headlamp-oidc/ca.crt
volumeMounts:
  - name: kubeconfig
    mountPath: /etc/headlamp/kubeconfig
  - name: oidc-ca
    mountPath: /etc/headlamp-oidc
volumes:
  - name: kubeconfig
    secret:
      secretName: headlamp-proxy-kubeconfig
  - name: oidc-ca
    secret:
      secretName: keycloak-oidc-ca
hostAliases:
  - ip: "${ingress_ip}"
    hostnames:
      - keycloak.node-01
ingress:
  enabled: true
  ingressClassName: nginx
  hosts:
    - host: headlamp.node-01
      paths:
        - path: /
          type: Prefix
EOF

helm upgrade --install headlamp headlamp/headlamp \
  --namespace "${headlamp_ns}" \
  -f /tmp/headlamp-values.yaml

kubectl -n "${headlamp_ns}" rollout status deployment/headlamp --timeout=240s

# Headlamp chart defaults include in-cluster flags; remove them to avoid creating the `main` context.
patched_main_context=false
first_arg=$(kubectl -n "${headlamp_ns}" get deploy headlamp -o jsonpath='{.spec.template.spec.containers[0].args[0]}' 2>/dev/null || true)
if [[ "${first_arg}" == "-in-cluster" ]]; then
  kubectl -n "${headlamp_ns}" patch deployment headlamp --type='json' \
    -p='[{"op":"remove","path":"/spec/template/spec/containers/0/args/0"}]' >/dev/null
  patched_main_context=true
fi

first_arg=$(kubectl -n "${headlamp_ns}" get deploy headlamp -o jsonpath='{.spec.template.spec.containers[0].args[0]}' 2>/dev/null || true)
if [[ "${first_arg}" == "-in-cluster-context-name=main" ]]; then
  kubectl -n "${headlamp_ns}" patch deployment headlamp --type='json' \
    -p='[{"op":"remove","path":"/spec/template/spec/containers/0/args/0"}]' >/dev/null
  patched_main_context=true
fi

if [[ "${patched_main_context}" == "true" ]]; then
  kubectl -n "${headlamp_ns}" rollout status deployment/headlamp --timeout=240s
fi

kubectl -n "${headlamp_ns}" get pods,svc,ingress -o wide
curl -I --max-time 10 http://headlamp.node-01 | head -n 10