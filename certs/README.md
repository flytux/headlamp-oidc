#### Generate certs and secrets

```
# 1) Generate keycloak, kube-oidc-proxy, headlamp certs
# 2) Generate keycloak CA secrets
# 3) Generate kubeconfig for kube-oidc-proxy with Keycloak oidc client

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

# kube-oidc-proxy mount
kubectl create secret generic keycloak-crt --from-file=keycloak.crt=keycloak.crt -n headlamp


# headlammp-proxy-kubeconfig 
# replace cluster-ca cert at kube-oidc-proxy-config file with kube-oidc-proxy.crt value
kubectl create secret generic headlamp-proxy-kubeconfig --from-file=config=kube-oidc-proxy-config -n headlamp
```