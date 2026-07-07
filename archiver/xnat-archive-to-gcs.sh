#!/bin/bash
# XNAT Archive to GCS — Nightly backup + automatic offload
# Downloads session data via the XNAT REST API and uploads to GCS.
# Runs as a Kubernetes CronJob.
set -euo pipefail

# ── Configuration (from environment) ────────────────────────────────
GCS_BUCKET="${GCS_BUCKET:?GCS_BUCKET must be set}"
XNAT_URL="${XNAT_URL:?XNAT_URL must be set}"
XNAT_USER="${XNAT_USER:?XNAT_USER must be set}"
XNAT_PASS="${XNAT_PASS:?XNAT_PASS must be set}"
DB_HOST="${DB_HOST:-xnat-web-postgresql.ais-xnat.svc.cluster.local}"
DB_NAME="${DB_NAME:-xnat}"
DB_USER="${DB_USER:-xnat}"
DB_PASS="${DB_PASS:-}"
WORK_DIR="${WORK_DIR:-/tmp/xnat-backup}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
die() { log "ERROR: $*"; exit 1; }

# Activate service account
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS" --quiet
else
    die "GOOGLE_APPLICATION_CREDENTIALS not set or file not found"
fi

mkdir -p "$WORK_DIR"

# ── Phase 1: Backup ────────────────────────────────────────────────
log "=== Phase 1: Backup ==="

# Get JSESSION token
JSESSION=$(curl -sf -u "${XNAT_USER}:${XNAT_PASS}" \
    "${XNAT_URL}/data/JSESSION") || die "Failed to authenticate to XNAT"
log "Authenticated to XNAT"

# Query all image sessions
SESSIONS_JSON=$(curl -sf -b "JSESSIONID=${JSESSION}" \
    "${XNAT_URL}/data/experiments?format=json&xsiType=xnat:imageSessionData") \
    || die "Failed to query sessions"

SESSION_COUNT=$(echo "$SESSIONS_JSON" | jq '.ResultSet.Result | length')
log "Found ${SESSION_COUNT} sessions to back up"

BACKED_UP=0
FAILED=0
EXIT_STATUS=0

# Use process substitution to avoid subshell counter issue
while IFS=$'\t' read -r project label session_id; do

    GCS_PATH="gs://${GCS_BUCKET}/sessions/${project}/${label}"

    # Check if already backed up by looking for a marker file in GCS
    if gsutil -q stat "${GCS_PATH}/.backup_complete" 2>/dev/null; then
        log "SKIP: ${project}/${label} already backed up"
        continue
    fi

    FILES_JSON=$(curl -sf -b "JSESSIONID=${JSESSION}" \
        "${XNAT_URL}/data/experiments/${session_id}/scans/ALL/files?format=json") || {
        log "WARN: Failed to list files for ${project}/${label} (${session_id})"
        FAILED=$((FAILED + 1))
        continue
    }

    FILE_COUNT=$(echo "$FILES_JSON" | jq '.ResultSet.Result | length')
    if [ "$FILE_COUNT" -eq 0 ]; then
        log "SKIP: ${project}/${label} (${session_id}) has no files to back up"
        continue
    fi

    # Download session as a ZIP via the XNAT REST API
    ZIP_FILE="${WORK_DIR}/${session_id}.zip"
    EXTRACT_DIR="${WORK_DIR}/${session_id}"
    log "Downloading ${project}/${label} (${session_id}, ${FILE_COUNT} files)..."

    HTTP_CODE=$(curl -sf -b "JSESSIONID=${JSESSION}" \
        -o "$ZIP_FILE" -w "%{http_code}" \
        "${XNAT_URL}/data/experiments/${session_id}/scans/ALL/files?format=zip") || true

    if [ "$HTTP_CODE" != "200" ] || [ ! -s "$ZIP_FILE" ]; then
        log "WARN: Failed to download ${project}/${label} (HTTP ${HTTP_CODE})"
        rm -f "$ZIP_FILE"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Extract and upload to GCS
    mkdir -p "$EXTRACT_DIR"
    if unzip -qo "$ZIP_FILE" -d "$EXTRACT_DIR" 2>/dev/null; then
        log "Syncing ${project}/${label} -> ${GCS_PATH}"
        if gsutil -m -q rsync -r "$EXTRACT_DIR" "${GCS_PATH}/" 2>&1; then
            # Write marker so we skip on next run
            echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" | gsutil -q cp - "${GCS_PATH}/.backup_complete"
            BACKED_UP=$((BACKED_UP + 1))
            log "OK: ${project}/${label} backed up"
        else
            log "WARN: Failed to upload ${project}/${label} to GCS"
            FAILED=$((FAILED + 1))
        fi
    else
        log "WARN: Failed to extract ${project}/${label} ZIP"
        FAILED=$((FAILED + 1))
    fi

    # Clean up temp files
    rm -rf "$ZIP_FILE" "$EXTRACT_DIR"
done < <(echo "$SESSIONS_JSON" | jq -r '.ResultSet.Result[] | [.project, .label, .ID] | @tsv')

log "Backup complete: ${BACKED_UP} synced, ${FAILED} failures"
if [ "$FAILED" -gt 0 ] && [ "${ARCHIVER_FAIL_ON_SESSION_ERRORS:-1}" != "0" ]; then
    EXIT_STATUS=1
fi

# ── Database dump ──────────────────────────────────────────────────
if [ -n "$DB_PASS" ]; then
    log "Dumping PostgreSQL database..."
    DATE_STAMP=$(date -u '+%Y%m%d-%H%M%S')
    export PGPASSWORD="$DB_PASS"
    # Use pg_dump from the PostgreSQL server itself via kubectl exec,
    # or fall back to direct connection if versions match
    if pg_dump -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" 2>/dev/null | \
       gzip | gsutil cp - "gs://${GCS_BUCKET}/db-backups/xnat-${DATE_STAMP}.sql.gz"; then
        log "Database dump uploaded to gs://${GCS_BUCKET}/db-backups/xnat-${DATE_STAMP}.sql.gz"
        # Keep only last 7 database backups
        gsutil ls "gs://${GCS_BUCKET}/db-backups/" 2>/dev/null | sort | head -n -7 | \
            xargs -r gsutil rm 2>/dev/null || true
    else
        log "WARN: Database dump failed (pg_dump version may not match server)"
        EXIT_STATUS=1
    fi
    unset PGPASSWORD
else
    log "SKIP: DB_PASS not set, skipping database dump"
fi

# Invalidate XNAT session
curl -sf -b "JSESSIONID=${JSESSION}" -X DELETE "${XNAT_URL}/data/JSESSION" 2>/dev/null || true

# Clean up work dir
rm -rf "$WORK_DIR"

log "=== Done ==="
exit "$EXIT_STATUS"
