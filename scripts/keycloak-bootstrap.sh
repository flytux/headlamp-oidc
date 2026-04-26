#!/usr/bin/env bash

set -euo pipefail

: "${KEYCLOAK_NS:=keycloak}"
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
