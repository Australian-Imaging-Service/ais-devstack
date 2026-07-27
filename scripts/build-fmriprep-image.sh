#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DOCKER_CMD="${DOCKER_CMD:-sudo docker}"
FMRIPREP_IMAGE="${FMRIPREP_IMAGE:-xnat/fmriprep:25.2.5-ais.2}"
FMRIPREP_BASE_IMAGE="${FMRIPREP_BASE_IMAGE:-nipreps/fmriprep:25.2.5}"
NEUROCONTAINERS_COMMIT="2a7fc6cfb64afc09f229dea3c64102f1cc68a7a4"
NEUROCONTAINERS_RECIPE_URL="https://raw.githubusercontent.com/neurodesk/neurocontainers/${NEUROCONTAINERS_COMMIT}/recipes/freesurfer/build.yaml"
FREESURFER_LICENSE_SHA256="3734f9de095b9d4dffb7d682004579e795ba6c197bf5b4db50571ac50ad7214c"
DOCKERFILE="${REPO_ROOT}/container-service/images/fmriprep/Dockerfile"

docker_cmd() {
  # DOCKER_CMD intentionally supports the repo convention of "sudo docker".
  # shellcheck disable=SC2086
  ${DOCKER_CMD} "$@"
}

for bin in curl awk sha256sum; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "Missing required command: ${bin}" >&2
    exit 1
  fi
done

if [[ ! -f "${DOCKERFILE}" ]]; then
  echo "Missing Dockerfile: ${DOCKERFILE}" >&2
  exit 1
fi

build_context="$(mktemp -d)"
license_file="${build_context}/license.txt"
cleanup() {
  rm -f "${license_file}"
  rmdir "${build_context}" 2>/dev/null || true
}
trap cleanup EXIT

curl -fsSL "${NEUROCONTAINERS_RECIPE_URL}" | awk '
  /^  - name: license[.]txt$/ { found=1; next }
  found && /^    contents: [|]-$/ { capture=1; next }
  capture && /^      / { sub(/^      /, ""); print; next }
  capture { exit }
' > "${license_file}"

if [[ "$(wc -l < "${license_file}")" -ne 4 ]]; then
  echo "The pinned Neurodesk recipe did not yield the expected four-line license" >&2
  exit 1
fi

actual_sha256="$(sha256sum "${license_file}" | awk '{print $1}')"
if [[ "${actual_sha256}" != "${FREESURFER_LICENSE_SHA256}" ]]; then
  echo "The pinned Neurodesk FreeSurfer license checksum did not match" >&2
  exit 1
fi
chmod 0600 "${license_file}"

echo "Building ${FMRIPREP_IMAGE} from ${FMRIPREP_BASE_IMAGE}"
docker_cmd build \
  --build-arg "BASE_IMAGE=${FMRIPREP_BASE_IMAGE}" \
  --build-arg "FREESURFER_LICENSE_SHA256=${FREESURFER_LICENSE_SHA256}" \
  --file "${DOCKERFILE}" \
  --tag "${FMRIPREP_IMAGE}" \
  "${build_context}"

docker_cmd run --rm --entrypoint python "${FMRIPREP_IMAGE}" -c \
  'from niworkflows.utils.misc import check_valid_fs_license; raise SystemExit(0 if check_valid_fs_license() else 1)'

echo "Built ${FMRIPREP_IMAGE}; FreeSurfer license validation passed"
