#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

XNAT_NAMESPACE="${XNAT_NAMESPACE:-ais-xnat}"
XNAT_SERVICE="${XNAT_SERVICE:-xnat-web}"
XNAT_ADMIN_SECRET="${XNAT_ADMIN_SECRET:-xnat-archiver-creds}"
XNAT_ADMIN_USER="${XNAT_ADMIN_USER:-admin}"
KUBECTL_CMD="${KUBECTL_CMD:-sudo kubectl}"
BIDSMAP_FILE="${BIDSMAP_FILE:-${REPO_ROOT}/container-service/bidsmap/site-bidsmap.json}"

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

if [[ ! -f "${BIDSMAP_FILE}" ]]; then
  echo "Missing BIDS map file: ${BIDSMAP_FILE}" >&2
  exit 1
fi

require_bin curl
require_bin jq
require_bin base64

jq -e '
  type == "array"
  and all(.[]; has("series_description") and has("bidsname"))
  and all(.[]; (.series_description | type == "string") and (.bidsname | type == "string"))
' "${BIDSMAP_FILE}" >/dev/null

XNAT_ADMIN_PASSWORD="$(kubectl_cmd -n "${XNAT_NAMESPACE}" get secret "${XNAT_ADMIN_SECRET}" -o jsonpath='{.data.password}' | base64 -d)"
if [[ -z "${XNAT_ADMIN_PASSWORD}" ]]; then
  echo "Admin password secret ${XNAT_NAMESPACE}/${XNAT_ADMIN_SECRET} is empty or missing key password" >&2
  exit 1
fi

XNAT_BASE_URL="$(api_url)"

echo "Installing site-wide BIDS map from ${BIDSMAP_FILE}"
payload_file="$(mktemp)"
trap 'rm -f "${payload_file}"' EXIT
jq -c . "${BIDSMAP_FILE}" | jq -R '{contents: .}' > "${payload_file}"

curl -sS -u "${XNAT_ADMIN_USER}:${XNAT_ADMIN_PASSWORD}" \
  -X PUT \
  -H "Content-Type: application/json" \
  --data-binary @"${payload_file}" \
  "${XNAT_BASE_URL}/data/config/bids/bidsmap" >/dev/null

installed_count="$(curl -sS -u "${XNAT_ADMIN_USER}:${XNAT_ADMIN_PASSWORD}" \
  "${XNAT_BASE_URL}/data/config/bids/bidsmap?contents=True" | jq 'length')"

expected_count="$(jq 'length' "${BIDSMAP_FILE}")"
if [[ "${installed_count}" != "${expected_count}" ]]; then
  echo "Installed BIDS map entry count ${installed_count} did not match expected ${expected_count}" >&2
  exit 1
fi

echo "Installed site-wide BIDS map with ${installed_count} entries"
