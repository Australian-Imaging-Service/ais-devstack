#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

XNAT_NAMESPACE="${XNAT_NAMESPACE:-ais-xnat}"
XNAT_SERVICE="${XNAT_SERVICE:-xnat-web}"
XNAT_ADMIN_SECRET="${XNAT_ADMIN_SECRET:-xnat-archiver-creds}"
XNAT_ADMIN_USER="${XNAT_ADMIN_USER:-admin}"
KUBECTL_CMD="${KUBECTL_CMD:-sudo kubectl}"

SETUP_COMMAND_JSON="${REPO_ROOT}/container-service/commands/xnat2bids-setup.json"
MRIQC_COMMAND_JSON="${REPO_ROOT}/container-service/commands/mriqc-session.json"

require_file() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    echo "Missing required file: ${path}" >&2
    exit 1
  fi
}

require_bin() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "Missing required command: ${bin}" >&2
    exit 1
  fi
}

kubectl_cmd() {
  # KUBECTL_CMD intentionally supports the repo convention of "sudo kubectl".
  # shellcheck disable=SC2086
  ${KUBECTL_CMD} "$@"
}

api_url() {
  if [[ -n "${XNAT_API_URL:-}" ]]; then
    printf '%s\n' "${XNAT_API_URL%/}"
    return
  fi

  local cluster_ip
  cluster_ip="$(kubectl_cmd -n "${XNAT_NAMESPACE}" get svc "${XNAT_SERVICE}" -o jsonpath='{.spec.clusterIP}')"
  if [[ -z "${cluster_ip}" || "${cluster_ip}" == "None" ]]; then
    echo "Could not determine cluster IP for service ${XNAT_NAMESPACE}/${XNAT_SERVICE}" >&2
    exit 1
  fi
  printf 'http://%s\n' "${cluster_ip}"
}

curl_xnat() {
  local method="$1"
  local path="$2"
  local data_file="${3:-}"
  local status body_file
  body_file="$(mktemp)"

  if [[ -n "${data_file}" ]]; then
    status="$(curl -sS -o "${body_file}" -w '%{http_code}' \
      -u "${XNAT_ADMIN_USER}:${XNAT_ADMIN_PASSWORD}" \
      -X "${method}" \
      -H 'Content-Type: application/json;charset=UTF-8' \
      --data-binary @"${data_file}" \
      "${XNAT_BASE_URL}${path}")"
  else
    status="$(curl -sS -o "${body_file}" -w '%{http_code}' \
      -u "${XNAT_ADMIN_USER}:${XNAT_ADMIN_PASSWORD}" \
      -X "${method}" \
      "${XNAT_BASE_URL}${path}")"
  fi

  if [[ "${status}" -lt 200 || "${status}" -ge 300 ]]; then
    echo "XNAT API ${method} ${path} failed with HTTP ${status}" >&2
    cat "${body_file}" >&2
    rm -f "${body_file}"
    exit 1
  fi

  cat "${body_file}"
  rm -f "${body_file}"
}

command_id_by_name() {
  local command_name="$1"
  curl_xnat GET '/xapi/commands' \
    | jq -r --arg name "${command_name}" '.[] | select(.name == $name) | .id' \
    | head -n 1
}

upsert_command() {
  local json_file="$1"
  local command_name existing_id tmp_file new_id
  command_name="$(jq -r '.name' "${json_file}")"
  existing_id="$(command_id_by_name "${command_name}")"

  if [[ -n "${existing_id}" && "${existing_id}" != "null" ]]; then
    tmp_file="$(mktemp)"
    jq --argjson id "${existing_id}" '. + {id: $id}' "${json_file}" > "${tmp_file}"
    curl_xnat POST "/xapi/commands/${existing_id}" "${tmp_file}" >/dev/null
    rm -f "${tmp_file}"
    printf '%s\n' "${existing_id}"
  else
    new_id="$(curl_xnat POST '/xapi/commands' "${json_file}" | jq -r '.')"
    printf '%s\n' "${new_id}"
  fi
}

set_public_visibility() {
  local command_id="$1"
  curl_xnat POST "/xapi/command/${command_id}/visibility/public" >/dev/null
}

enable_wrapper_sitewide() {
  local command_id="$1"
  local wrapper_name="$2"
  curl_xnat PUT "/xapi/commands/${command_id}/wrappers/${wrapper_name}/enabled" >/dev/null
}

verify_wrapper_enabled() {
  local command_id="$1"
  local wrapper_name="$2"
  local enabled
  enabled="$(curl_xnat GET "/xapi/commands/${command_id}/wrappers/${wrapper_name}/enabled" | jq -r '.')"
  if [[ "${enabled}" != "true" ]]; then
    echo "Wrapper ${wrapper_name} for command ${command_id} is not enabled site-wide" >&2
    exit 1
  fi
}

require_file "${SETUP_COMMAND_JSON}"
require_file "${MRIQC_COMMAND_JSON}"
require_bin curl
require_bin jq
require_bin base64

jq empty "${SETUP_COMMAND_JSON}"
jq empty "${MRIQC_COMMAND_JSON}"

XNAT_ADMIN_PASSWORD="$(kubectl_cmd -n "${XNAT_NAMESPACE}" get secret "${XNAT_ADMIN_SECRET}" -o jsonpath='{.data.password}' | base64 -d)"
if [[ -z "${XNAT_ADMIN_PASSWORD}" ]]; then
  echo "Admin password secret ${XNAT_NAMESPACE}/${XNAT_ADMIN_SECRET} is empty or missing key password" >&2
  exit 1
fi

XNAT_BASE_URL="$(api_url)"

echo "Installing Container Service commands into ${XNAT_BASE_URL}"
setup_id="$(upsert_command "${SETUP_COMMAND_JSON}")"
mriqc_id="$(upsert_command "${MRIQC_COMMAND_JSON}")"

set_public_visibility "${setup_id}"
set_public_visibility "${mriqc_id}"
enable_wrapper_sitewide "${mriqc_id}" "mriqc-session"
verify_wrapper_enabled "${mriqc_id}" "mriqc-session"

echo "Installed xnat2bids setup command id ${setup_id}"
echo "Installed MRIQC command id ${mriqc_id}; wrapper mriqc-session is enabled site-wide"
