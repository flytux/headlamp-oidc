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
: "${SYNC_CLIENT_SECRET_FILES:=true}"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd)

: "${HEADLAMP_OIDC_SECRET_FILE:=${REPO_ROOT}/manifests/keycloak/headlamp-oidc-secret.yaml}"
: "${KUBE_OIDC_PROXY_CONFIG_FILE:=${REPO_ROOT}/manifests/keycloak/headlamp-proxy-kubeconfig.yaml}"

KEYCLOAK_POD=$(kubectl -n "${KEYCLOAK_NS}" get pod -l app=keycloak -o jsonpath='{.items[0].metadata.name}')

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&|\\]/\\&/g'
}

extract_client_secret() {
  printf '%s\n' "$1" | sed -n 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

replace_key_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local escaped_value

  if [[ ! -f "${file}" ]]; then
    echo "Missing file: ${file}" >&2
    return 1
  fi

  if ! grep -qE "^[[:space:]]*${key}:" "${file}"; then
    echo "Key ${key} not found in ${file}" >&2
    return 1
  fi

  escaped_value=$(escape_sed_replacement "${value}")
  sed -i -E "s|^([[:space:]]*${key}:[[:space:]]*).*$|\1${escaped_value}|" "${file}"
}

sync_client_secret_files() {
  local client_secret="$1"

  replace_key_value "${HEADLAMP_OIDC_SECRET_FILE}" "clientSecret" "${client_secret}"
  replace_key_value "${KUBE_OIDC_PROXY_CONFIG_FILE}" "client-secret" "${client_secret}"

  kubectl  -n "${KEYCLOAK_NS}" delete secret -l idp=keycloak

  kubectl apply -f "${HEADLAMP_OIDC_SECRET_FILE}"
  kubectl apply -f "${KUBE_OIDC_PROXY_CONFIG_FILE}"

  echo "Synced client secret to ${HEADLAMP_OIDC_SECRET_FILE}" >&2
  echo "Synced client secret to ${KUBE_OIDC_PROXY_CONFIG_FILE}" >&2
}

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

CLIENT_SECRET_JSON=$(kubectl -n "${KEYCLOAK_NS}" exec "${KEYCLOAK_POD}" -- /opt/keycloak/bin/kcadm.sh get clients/"${CLIENT_UUID}"/client-secret -r "${REALM}")
CLIENT_SECRET=$(extract_client_secret "${CLIENT_SECRET_JSON}")

printf '%s\n' "${CLIENT_SECRET_JSON}"

if [[ -z "${CLIENT_SECRET}" ]]; then
  echo "Failed to parse Keycloak client secret" >&2
  exit 1
fi

if [[ "${SYNC_CLIENT_SECRET_FILES}" == "true" ]]; then
  sync_client_secret_files "${CLIENT_SECRET}"
fi

