#!/usr/bin/env bash

set -euo pipefail

: "${AUTH_SERVER_URL:=https://spring-auth.node-01}"
: "${BOOTSTRAP_ADMIN_TOKEN:=change-me-bootstrap-token}"
: "${CLIENT_ID:=headlamp}"
: "${CLIENT_SECRET:=change-me-with-real-client-secret}"
: "${REDIRECT_URI:=http://headlamp.node-01/oidc-callback}"
: "${CLIENT_SCOPES:=openid,profile,email,groups}"
: "${ADMIN_USER:=admin}"
: "${ADMIN_PASSWORD:=password}"
: "${ADMIN_GROUPS:=hl-admins}"
: "${DEV_USER:=dev}"
: "${DEV_PASSWORD:=password}"
: "${DEV_GROUPS:=hl-devs}"
: "${CURL_INSECURE:=true}"
: "${SHOW_BOOTSTRAP_SECRETS:=false}"

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

json_array_from_csv() {
  local csv="$1"
  local items=()
  local item
  local IFS=','

  read -r -a items <<< "$csv"

  for item in "${items[@]}"; do
    item="$(trim "$item")"
    if [[ -z "$item" ]]; then
      continue
    fi
    printf '"%s",' "${item//\"/\\\"}"
  done | sed 's/,$//'
}

mask_value() {
  local value="$1"
  if [[ "${SHOW_BOOTSTRAP_SECRETS}" == "true" ]]; then
    printf '%s' "$value"
  else
    printf '[REDACTED]'
  fi
}

mask_payload() {
  sed -E \
    -e 's/("clientSecret": ")[^"]+/\1[REDACTED]/' \
    -e 's/("password": ")[^"]+/\1[REDACTED]/g'
}

curl_args=(
  --fail
  --show-error
  --silent
  -H "Content-Type: application/json"
  -H "X-Bootstrap-Token: ${BOOTSTRAP_ADMIN_TOKEN}"
)

if [[ "${CURL_INSECURE}" == "true" ]]; then
  curl_args+=(-k)
fi

request_url="${AUTH_SERVER_URL%/}/bootstrap/registrations"

payload=$(cat <<JSON
{
  "client": {
    "clientId": "${CLIENT_ID}",
    "clientSecret": "${CLIENT_SECRET}",
    "redirectUri": "${REDIRECT_URI}",
    "scopes": [$(json_array_from_csv "${CLIENT_SCOPES}")]
  },
  "users": [
    {
      "username": "${ADMIN_USER}",
      "password": "${ADMIN_PASSWORD}",
      "groups": [$(json_array_from_csv "${ADMIN_GROUPS}")]
    },
    {
      "username": "${DEV_USER}",
      "password": "${DEV_PASSWORD}",
      "groups": [$(json_array_from_csv "${DEV_GROUPS}")]
    }
  ]
}
JSON
)

printf '== Bootstrap request ==\n'
printf 'URL: %s\n' "${request_url}"
printf 'Headers:\n'
printf '  Content-Type: application/json\n'
printf '  X-Bootstrap-Token: %s\n' "$(mask_value "${BOOTSTRAP_ADMIN_TOKEN}")"
printf 'Payload:\n%s\n' "$(if [[ "${SHOW_BOOTSTRAP_SECRETS}" == "true" ]]; then printf '%s' "${payload}"; else printf '%s' "${payload}" | mask_payload; fi)"

response_file="$(mktemp)"
trap 'rm -f "${response_file}"' EXIT

set +e
http_status=$(
  curl "${curl_args[@]}" \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    --data "${payload}" \
    "${request_url}"
)
curl_exit=$?
set -e

response_body="$(cat "${response_file}")"

printf '== Bootstrap response ==\n'
printf 'HTTP %s\n' "${http_status}"
printf '%s\n' "${response_body}"

if [[ ${curl_exit} -ne 0 ]]; then
  exit "${curl_exit}"
fi

if [[ ! "${http_status}" =~ ^2 ]]; then
  exit 1
fi
