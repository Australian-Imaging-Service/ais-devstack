#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

XNAT_NAMESPACE="${XNAT_NAMESPACE:-ais-xnat}"
XNAT_SERVICE="${XNAT_SERVICE:-xnat-web}"
XNAT_ADMIN_SECRET="${XNAT_ADMIN_SECRET:-xnat-archiver-creds}"
XNAT_ADMIN_USER="${XNAT_ADMIN_USER:-admin}"
KUBECTL_CMD="${KUBECTL_CMD:-sudo kubectl}"
CONTAINER_SERVICE_ENABLE_PROJECTS="${CONTAINER_SERVICE_ENABLE_PROJECTS:-${MRIQC_ENABLE_PROJECTS:-all}}"
XNAT_COOKIE_JAR=""

SETUP_COMMAND_JSON="${REPO_ROOT}/container-service/commands/xnat2bids-setup.json"
DCM2NIIX_SETUP_COMMAND_JSON="${REPO_ROOT}/container-service/commands/dcm2niix-setup.json"
MRIQC_COMMAND_JSON="${REPO_ROOT}/container-service/commands/mriqc-session.json"
DCM2BIDS_COMMAND_JSON="${REPO_ROOT}/container-service/commands/dcm2bids-session.json"
DCM2NIIX_COMMAND_JSON="${REPO_ROOT}/container-service/commands/dcm2niix-scan.json"
FMRIPREP_COMMAND_JSON="${REPO_ROOT}/container-service/commands/fmriprep-session.json"
ASLPREP_COMMAND_JSON="${REPO_ROOT}/container-service/commands/aslprep-session.json"
QSMXT_COMMAND_JSON="${REPO_ROOT}/container-service/commands/qsmxt-session.json"
MUSCLEMAP_COMMAND_JSON="${REPO_ROOT}/container-service/commands/musclemap-scan.json"
SCT_COMMAND_JSON="${REPO_ROOT}/container-service/commands/spinalcordtoolbox-scan.json"

COMMAND_JSON_FILES=(
  "${SETUP_COMMAND_JSON}"
  "${DCM2NIIX_SETUP_COMMAND_JSON}"
  "${MRIQC_COMMAND_JSON}"
  "${DCM2BIDS_COMMAND_JSON}"
  "${DCM2NIIX_COMMAND_JSON}"
  "${FMRIPREP_COMMAND_JSON}"
  "${ASLPREP_COMMAND_JSON}"
  "${QSMXT_COMMAND_JSON}"
  "${MUSCLEMAP_COMMAND_JSON}"
  "${SCT_COMMAND_JSON}"
)

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
      -b "${XNAT_COOKIE_JAR}" \
      -X "${method}" \
      -H 'Content-Type: application/json;charset=UTF-8' \
      --data-binary @"${data_file}" \
      "${XNAT_BASE_URL}${path}")"
  else
    status="$(curl -sS -o "${body_file}" -w '%{http_code}' \
      -b "${XNAT_COOKIE_JAR}" \
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

start_xnat_session() {
  local status body_file
  XNAT_COOKIE_JAR="$(mktemp)"
  body_file="$(mktemp)"
  status="$(curl -sS -o "${body_file}" -w '%{http_code}' \
    -c "${XNAT_COOKIE_JAR}" \
    -u "${XNAT_ADMIN_USER}:${XNAT_ADMIN_PASSWORD}" \
    -X POST \
    "${XNAT_BASE_URL}/data/JSESSION")"

  if [[ "${status}" -lt 200 || "${status}" -ge 300 ]]; then
    echo "XNAT login failed with HTTP ${status}" >&2
    cat "${body_file}" >&2
    rm -f "${body_file}"
    exit 1
  fi

  rm -f "${body_file}"
}

end_xnat_session() {
  if [[ -n "${XNAT_COOKIE_JAR}" && -f "${XNAT_COOKIE_JAR}" ]]; then
    curl -sS -o /dev/null -b "${XNAT_COOKIE_JAR}" -X DELETE "${XNAT_BASE_URL}/data/JSESSION" || true
    rm -f "${XNAT_COOKIE_JAR}"
  fi
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

enable_wrapper_for_project() {
  local project="$1"
  local command_id="$2"
  local wrapper_name="$3"
  curl_xnat PUT "/xapi/projects/${project}/commands/${command_id}/wrappers/${wrapper_name}/enabled" >/dev/null
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

project_ids_to_enable() {
  if [[ "${CONTAINER_SERVICE_ENABLE_PROJECTS}" == "all" ]]; then
    curl_xnat GET '/data/projects?format=json' | jq -r '.ResultSet.Result[].ID'
  elif [[ -n "${CONTAINER_SERVICE_ENABLE_PROJECTS}" && "${CONTAINER_SERVICE_ENABLE_PROJECTS}" != "none" ]]; then
    printf '%s\n' "${CONTAINER_SERVICE_ENABLE_PROJECTS}" | tr ',' '\n' | awk 'NF {print $1}'
  fi
}

enable_wrapper_for_projects() {
  local command_id="$1"
  local wrapper_name="$2"
  local project

  while IFS= read -r project; do
    [[ -n "${project}" ]] || continue
    enable_wrapper_for_project "${project}" "${command_id}" "${wrapper_name}"
    echo "Enabled ${wrapper_name} for project ${project}"
  done < <(project_ids_to_enable)
}

require_bin curl
require_bin jq
require_bin base64

for command_json in "${COMMAND_JSON_FILES[@]}"; do
  require_file "${command_json}"
  jq empty "${command_json}"
done

XNAT_ADMIN_PASSWORD="$(kubectl_cmd -n "${XNAT_NAMESPACE}" get secret "${XNAT_ADMIN_SECRET}" -o jsonpath='{.data.password}' | base64 -d)"
if [[ -z "${XNAT_ADMIN_PASSWORD}" ]]; then
  echo "Admin password secret ${XNAT_NAMESPACE}/${XNAT_ADMIN_SECRET} is empty or missing key password" >&2
  exit 1
fi

XNAT_BASE_URL="$(api_url)"
trap end_xnat_session EXIT
start_xnat_session

echo "Installing Container Service commands into ${XNAT_BASE_URL}"
setup_id="$(upsert_command "${SETUP_COMMAND_JSON}")"
dcm2niix_setup_id="$(upsert_command "${DCM2NIIX_SETUP_COMMAND_JSON}")"
mriqc_id="$(upsert_command "${MRIQC_COMMAND_JSON}")"
dcm2bids_id="$(upsert_command "${DCM2BIDS_COMMAND_JSON}")"
dcm2niix_id="$(upsert_command "${DCM2NIIX_COMMAND_JSON}")"
fmriprep_id="$(upsert_command "${FMRIPREP_COMMAND_JSON}")"
aslprep_id="$(upsert_command "${ASLPREP_COMMAND_JSON}")"
qsmxt_id="$(upsert_command "${QSMXT_COMMAND_JSON}")"
musclemap_id="$(upsert_command "${MUSCLEMAP_COMMAND_JSON}")"
sct_id="$(upsert_command "${SCT_COMMAND_JSON}")"

set_public_visibility "${setup_id}"
set_public_visibility "${dcm2niix_setup_id}"
set_public_visibility "${mriqc_id}"
set_public_visibility "${dcm2bids_id}"
set_public_visibility "${dcm2niix_id}"
set_public_visibility "${fmriprep_id}"
set_public_visibility "${aslprep_id}"
set_public_visibility "${qsmxt_id}"
set_public_visibility "${musclemap_id}"
set_public_visibility "${sct_id}"

enable_wrapper_sitewide "${mriqc_id}" "mriqc-session"
enable_wrapper_sitewide "${dcm2bids_id}" "dcm2bids-session-session"
enable_wrapper_sitewide "${dcm2niix_id}" "dcm2niix-scan"
enable_wrapper_sitewide "${fmriprep_id}" "fmriprep-session"
enable_wrapper_sitewide "${aslprep_id}" "aslprep-session"
enable_wrapper_sitewide "${qsmxt_id}" "qsmxt-session"
enable_wrapper_sitewide "${musclemap_id}" "musclemap-scan"
enable_wrapper_sitewide "${musclemap_id}" "musclemap-dicom-scan"
enable_wrapper_sitewide "${sct_id}" "spinalcordtoolbox-deepseg-scan"
enable_wrapper_sitewide "${sct_id}" "spinalcordtoolbox-deepseg-dicom-scan"

enable_wrapper_for_projects "${mriqc_id}" "mriqc-session"
enable_wrapper_for_projects "${dcm2bids_id}" "dcm2bids-session-session"
enable_wrapper_for_projects "${dcm2niix_id}" "dcm2niix-scan"
enable_wrapper_for_projects "${fmriprep_id}" "fmriprep-session"
enable_wrapper_for_projects "${aslprep_id}" "aslprep-session"
enable_wrapper_for_projects "${qsmxt_id}" "qsmxt-session"
enable_wrapper_for_projects "${musclemap_id}" "musclemap-scan"
enable_wrapper_for_projects "${musclemap_id}" "musclemap-dicom-scan"
enable_wrapper_for_projects "${sct_id}" "spinalcordtoolbox-deepseg-scan"
enable_wrapper_for_projects "${sct_id}" "spinalcordtoolbox-deepseg-dicom-scan"

verify_wrapper_enabled "${mriqc_id}" "mriqc-session"
verify_wrapper_enabled "${dcm2bids_id}" "dcm2bids-session-session"
verify_wrapper_enabled "${dcm2niix_id}" "dcm2niix-scan"
verify_wrapper_enabled "${fmriprep_id}" "fmriprep-session"
verify_wrapper_enabled "${aslprep_id}" "aslprep-session"
verify_wrapper_enabled "${qsmxt_id}" "qsmxt-session"
verify_wrapper_enabled "${musclemap_id}" "musclemap-scan"
verify_wrapper_enabled "${musclemap_id}" "musclemap-dicom-scan"
verify_wrapper_enabled "${sct_id}" "spinalcordtoolbox-deepseg-scan"
verify_wrapper_enabled "${sct_id}" "spinalcordtoolbox-deepseg-dicom-scan"

echo "Installed xnat2bids setup command id ${setup_id}"
echo "Installed dcm2niix setup command id ${dcm2niix_setup_id}"
echo "Installed MRIQC command id ${mriqc_id}; wrapper mriqc-session is enabled site-wide"
echo "Installed DICOM-to-BIDS command id ${dcm2bids_id}; wrapper dcm2bids-session-session is enabled site-wide"
echo "Installed dcm2niix command id ${dcm2niix_id}; wrapper dcm2niix-scan is enabled site-wide"
echo "Installed fMRIPrep command id ${fmriprep_id}; wrapper fmriprep-session is enabled site-wide"
echo "Installed ASLPrep command id ${aslprep_id}; wrapper aslprep-session is enabled site-wide"
echo "Installed QSMxT command id ${qsmxt_id}; wrapper qsmxt-session is enabled site-wide"
echo "Installed MuscleMap command id ${musclemap_id}; wrappers musclemap-scan and musclemap-dicom-scan are enabled site-wide"
echo "Installed Spinal Cord Toolbox command id ${sct_id}; wrappers spinalcordtoolbox-deepseg-scan and spinalcordtoolbox-deepseg-dicom-scan are enabled site-wide"
