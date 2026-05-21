#!/usr/bin/env bash
#
# Idempotent setup of the ais-edge upload service account on XNAT.
#
# Creates (or re-asserts):
#   - localdb XNAT user `edge-uploader` (password generated on first run)
#   - site-wide Administrator role
#   - Owner membership on a set of XNAT projects (created if missing)
#   - k8s secret `ais-xnat/edge-uploader-creds` holding the credentials
#
# Safe to re-run: existing user/projects/role/secret are reused, password is
# not rotated unless the secret is missing.
#
# Env overrides:
#   XNAT_URL          default: https://xnat-lucas.neurodesk.org
#   XNAT_NAMESPACE    default: ais-xnat
#   EDGE_USER         default: edge-uploader
#   EDGE_EMAIL        default: mail.neurodesk@gmail.com
#   EDGE_PROJECTS     default: "polimeni ennis dicomtest misc Siemens_cimax"
#   ADMIN_SECRET      default: xnat-archiver-creds  (in $XNAT_NAMESPACE)
#   EDGE_SECRET       default: edge-uploader-creds  (in $XNAT_NAMESPACE)

set -euo pipefail

XNAT_URL="${XNAT_URL:-https://xnat-lucas.neurodesk.org}"
XNAT_NAMESPACE="${XNAT_NAMESPACE:-ais-xnat}"
EDGE_USER="${EDGE_USER:-edge-uploader}"
EDGE_EMAIL="${EDGE_EMAIL:-mail.neurodesk@gmail.com}"
EDGE_PROJECTS="${EDGE_PROJECTS:-polimeni ennis dicomtest misc Siemens_cimax}"
ADMIN_SECRET="${ADMIN_SECRET:-xnat-archiver-creds}"
EDGE_SECRET="${EDGE_SECRET:-edge-uploader-creds}"

log() { printf '[edge-uploader] %s\n' "$*" >&2; }

# --- prerequisites ----------------------------------------------------------
for bin in sudo kubectl curl openssl python3; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 1; }
done

# --- admin credentials ------------------------------------------------------
ADMIN_USER="$(sudo kubectl -n "$XNAT_NAMESPACE" get secret "$ADMIN_SECRET" \
  -o jsonpath='{.data.username}' | base64 -d)"
ADMIN_PW="$(sudo kubectl -n "$XNAT_NAMESPACE" get secret "$ADMIN_SECRET" \
  -o jsonpath='{.data.password}' | base64 -d)"
[[ -n "$ADMIN_USER" && -n "$ADMIN_PW" ]] || { echo "could not read admin creds from $ADMIN_SECRET" >&2; exit 1; }

xnat_curl() {
  curl -sS -u "${ADMIN_USER}:${ADMIN_PW}" -o /dev/null -w '%{http_code}' "$@"
}

# Reachability check
code="$(curl -sS -o /dev/null -w '%{http_code}' -u "${ADMIN_USER}:${ADMIN_PW}" \
  -X POST "${XNAT_URL}/data/JSESSION" || echo "000")"
[[ "$code" == "200" ]] || { echo "XNAT unreachable or admin auth failed (HTTP $code) at $XNAT_URL" >&2; exit 1; }
log "XNAT reachable at $XNAT_URL (admin JSESSION HTTP $code)"

# --- edge-uploader password (from secret, or generate) ----------------------
if sudo kubectl -n "$XNAT_NAMESPACE" get secret "$EDGE_SECRET" >/dev/null 2>&1; then
  EDGE_PW="$(sudo kubectl -n "$XNAT_NAMESPACE" get secret "$EDGE_SECRET" \
    -o jsonpath='{.data.password}' | base64 -d)"
  log "reusing password from existing secret $EDGE_SECRET"
  EDGE_PW_NEW=0
else
  EDGE_PW="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
  log "generated new password for $EDGE_USER"
  EDGE_PW_NEW=1
fi

# --- create or update user --------------------------------------------------
user_code="$(curl -sS -u "${ADMIN_USER}:${ADMIN_PW}" -o /dev/null -w '%{http_code}' \
  "${XNAT_URL}/xapi/users/${EDGE_USER}")"

if [[ "$user_code" == "200" ]]; then
  log "user $EDGE_USER already exists"
else
  log "creating user $EDGE_USER"
  body=$(python3 -c "import json,sys; print(json.dumps({
    'username': '$EDGE_USER',
    'password': '''$EDGE_PW''',
    'email': '$EDGE_EMAIL',
    'firstName': 'Edge',
    'lastName': 'Uploader',
    'enabled': True,
    'verified': True
  }))")
  code="$(curl -sS -u "${ADMIN_USER}:${ADMIN_PW}" -o /dev/null -w '%{http_code}' \
    -X POST "${XNAT_URL}/xapi/users" \
    -H "Content-Type: application/json" -d "$body")"
  [[ "$code" == "201" || "$code" == "200" ]] || { echo "user create failed: HTTP $code" >&2; exit 1; }
fi

# --- site-wide Administrator role -------------------------------------------
log "ensuring Administrator role on $EDGE_USER"
xnat_curl -X PUT "${XNAT_URL}/xapi/users/${EDGE_USER}/roles/Administrator" >/dev/null

# --- projects: create if missing, assign Owner ------------------------------
for proj in $EDGE_PROJECTS; do
  code="$(curl -sS -u "${ADMIN_USER}:${ADMIN_PW}" -o /dev/null -w '%{http_code}' \
    "${XNAT_URL}/data/projects/${proj}?format=json")"
  if [[ "$code" == "200" ]]; then
    log "project $proj exists"
  else
    log "creating project $proj"
    xnat_curl -X PUT "${XNAT_URL}/data/projects/${proj}?name=${proj}&secondary_ID=${proj}" >/dev/null
  fi
  log "ensuring $EDGE_USER is Owner of $proj"
  xnat_curl -X PUT "${XNAT_URL}/data/projects/${proj}/users/Owners/${EDGE_USER}" >/dev/null
done

# --- k8s secret -------------------------------------------------------------
if (( EDGE_PW_NEW == 1 )); then
  log "creating k8s secret $EDGE_SECRET"
  sudo kubectl -n "$XNAT_NAMESPACE" create secret generic "$EDGE_SECRET" \
    --from-literal=username="$EDGE_USER" \
    --from-literal=password="$EDGE_PW" \
    --from-literal=xnat_url="$XNAT_URL" \
    --from-literal=email="$EDGE_EMAIL"
fi

# --- verification -----------------------------------------------------------
log "verifying $EDGE_USER login"
who="$(curl -sS -u "${EDGE_USER}:${EDGE_PW}" "${XNAT_URL}/xapi/users/username")"
[[ "$who" == "$EDGE_USER" ]] || { echo "login verification failed (got '$who')" >&2; exit 1; }

log "done. projects visible to $EDGE_USER:"
curl -sS -u "${EDGE_USER}:${EDGE_PW}" "${XNAT_URL}/data/projects?format=json" \
  | python3 -c "import json,sys; [print('  - '+p['ID']) for p in json.load(sys.stdin)['ResultSet']['Result']]"

cat <<EOF

Credentials for ais-edge config/management.env:
  XNAT_URL=${XNAT_URL}
  XNAT_USER=${EDGE_USER}
  XNAT_PASS=\$(sudo kubectl -n ${XNAT_NAMESPACE} get secret ${EDGE_SECRET} -o jsonpath='{.data.password}' | base64 -d)
EOF
