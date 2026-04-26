#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

kubectl -n keycloak exec deploy/keycloak -- /opt/keycloak/bin/kcadm.sh \
  config credentials --server http://127.0.0.1:8080 --realm master \
  --user admin --password admin123 >/dev/null 2>&1

client_uuid=$(kubectl -n keycloak exec deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get clients -r headlamp -q clientId=headlamp \
  --fields id --format csv --noquotes | tail -n 1)

client_secret=$(kubectl -n keycloak exec deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get clients/"${client_uuid}"/client-secret -r headlamp \
  | grep -o '"value" : "[^"]*"' | cut -d '"' -f4)

admin_response=$(curl -sk \
  -d client_id=headlamp \
  -d client_secret="${client_secret}" \
  -d username=headlamp-admin \
  -d password='ChangeMe-Admin-Password!' \
  -d scope=openid \
  -d grant_type=password \
  https://keycloak.node-01/realms/headlamp/protocol/openid-connect/token)

dev_response=$(curl -sk \
  -d client_id=headlamp \
  -d client_secret="${client_secret}" \
  -d username=headlamp-dev \
  -d password='ChangeMe-Dev-Password!' \
  -d scope=openid \
  -d grant_type=password \
  https://keycloak.node-01/realms/headlamp/protocol/openid-connect/token)

admin_token=$(printf '%s' "${admin_response}" | python3 -c 'import sys, json; data=json.load(sys.stdin); print(data.get("id_token", ""))')
dev_token=$(printf '%s' "${dev_response}" | python3 -c 'import sys, json; data=json.load(sys.stdin); print(data.get("id_token", ""))')

if [[ -z "${admin_token}" || -z "${dev_token}" ]]; then
  echo "admin token response: ${admin_response}"
  echo "dev token response: ${dev_response}"
  exit 1
fi

printf 'admin get pods: '
admin_get=$(kubectl --server=https://127.0.0.1:9443 --insecure-skip-tls-verify --token="${admin_token}" auth can-i get pods -A 2>/dev/null || true)
printf '%s\n' "${admin_get}"

printf 'admin delete pods: '
admin_delete=$(kubectl --server=https://127.0.0.1:9443 --insecure-skip-tls-verify --token="${admin_token}" auth can-i delete pods -A 2>/dev/null || true)
printf '%s\n' "${admin_delete}"

printf 'dev get pods: '
dev_get=$(kubectl --server=https://127.0.0.1:9443 --insecure-skip-tls-verify --token="${dev_token}" auth can-i get pods -A 2>/dev/null || true)
printf '%s\n' "${dev_get}"

printf 'dev delete pods: '
dev_delete=$(kubectl --server=https://127.0.0.1:9443 --insecure-skip-tls-verify --token="${dev_token}" auth can-i delete pods -A 2>/dev/null || true)
printf '%s\n' "${dev_delete}"

if [[ "${admin_get}" == "yes" && "${admin_delete}" == "yes" && "${dev_get}" == "yes" && "${dev_delete}" == "no" ]]; then
  echo "RBAC validation passed"
  exit 0
fi

echo "RBAC validation failed"
exit 1