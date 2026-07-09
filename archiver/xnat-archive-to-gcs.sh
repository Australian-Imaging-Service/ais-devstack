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
SESSION_ID_FILTER="${SESSION_ID_FILTER:-}"

# Optional local offload. When enabled, files in the local XNAT archive are
# replaced with symlinks only after the matching object-store file is visible
# and the size matches. Catalog/session XML files are kept local.
OFFLOAD_AFTER_BACKUP="${OFFLOAD_AFTER_BACKUP:-0}"
OFFLOAD_EXISTING_BACKUPS="${OFFLOAD_EXISTING_BACKUPS:-0}"
OFFLOAD_DRY_RUN="${OFFLOAD_DRY_RUN:-0}"
XNAT_ARCHIVE_ROOT="${XNAT_ARCHIVE_ROOT:-/data/xnat/archive}"
OBJECT_STORE_MOUNT="${OBJECT_STORE_MOUNT:-/data/xnat/object-store}"
OBJECT_STORE_LINK_PREFIX="${OBJECT_STORE_LINK_PREFIX:-${OBJECT_STORE_MOUNT}/sessions}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
die() { log "ERROR: $*"; exit 1; }

# Activate service account
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS" --quiet
else
    die "GOOGLE_APPLICATION_CREDENTIALS not set or file not found"
fi

mkdir -p "$WORK_DIR"

truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

json_count() {
    jq '.ResultSet.Result | length' "$1"
}

download_zip() {
    local name="$1"
    local url="$2"
    local zip_file="$3"
    local extract_dir="$4"

    local http_code
    http_code=$(curl -sf -b "JSESSIONID=${JSESSION}" \
        -o "$zip_file" -w "%{http_code}" "$url") || true

    if [ "$http_code" != "200" ] || [ ! -s "$zip_file" ]; then
        log "WARN: Failed to download ${name} (HTTP ${http_code})"
        rm -f "$zip_file"
        return 1
    fi

    if ! unzip -qo "$zip_file" -d "$extract_dir" 2>/dev/null; then
        log "WARN: Failed to extract ${name} ZIP"
        rm -f "$zip_file"
        return 1
    fi

    rm -f "$zip_file"
    return 0
}

local_session_dir() {
    local project="$1"
    local label="$2"
    local default_dir="${XNAT_ARCHIVE_ROOT}/${project}/arc001/${label}"
    local found

    if [ -d "$default_dir" ]; then
        printf '%s\n' "$default_dir"
        return 0
    fi

    found=$(find "$XNAT_ARCHIVE_ROOT" -maxdepth 4 -type d -path "*/arc001/${label}" 2>/dev/null | head -1 || true)
    if [ -n "$found" ]; then
        printf '%s\n' "$found"
        return 0
    fi

    printf '%s\n' "$default_dir"
    return 0
}

should_keep_local() {
    local path="$1"
    case "$path" in
        *.xml|*/.*|*.backup_complete) return 0 ;;
        *) return 1 ;;
    esac
}

matching_object_file() {
    local candidate="$1"
    local local_size="$2"
    local object_size

    if [ ! -f "$candidate" ]; then
        return 1
    fi
    object_size=$(stat -c '%s' "$candidate")
    [ "$object_size" = "$local_size" ]
}

resolve_object_file() {
    local object_session="$1"
    local label="$2"
    local rel="$3"
    local local_size="$4"
    local candidate resource filename scan remainder found

    candidate="${object_session}/${rel}"
    if matching_object_file "$candidate" "$local_size"; then
        printf '%s\n' "$candidate"
        return 0
    fi

    case "$rel" in
        RESOURCES/*/*)
            resource="${rel#RESOURCES/}"
            resource="${resource%%/*}"
            filename="${rel#RESOURCES/${resource}/}"
            candidate="${object_session}/${label}/resources/${resource}/files/${filename}"
            if matching_object_file "$candidate" "$local_size"; then
                printf '%s\n' "$candidate"
                return 0
            fi
            ;;
        SCANS/*/*/*)
            scan="${rel#SCANS/}"
            scan="${scan%%/*}"
            remainder="${rel#SCANS/${scan}/}"
            resource="${remainder%%/*}"
            filename="${remainder#${resource}/}"
            for candidate in \
                "${object_session}/${label}/scans/${scan}/resources/${resource}/files/${filename}" \
                "${object_session}/${label}/scans/${scan}-"*/"resources/${resource}/files/${filename}"; do
                if matching_object_file "$candidate" "$local_size"; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
            done
            ;;
    esac

    filename="${rel##*/}"
    found=$(find "$object_session" -type f -name "$filename" -size "${local_size}c" 2>/dev/null | head -1 || true)
    if [ -n "$found" ]; then
        printf '%s\n' "$found"
        return 0
    fi

    return 1
}

offload_session() {
    local project="$1"
    local label="$2"
    local session_dir
    session_dir=$(local_session_dir "$project" "$label")

    if ! truthy "$OFFLOAD_AFTER_BACKUP" && ! truthy "$OFFLOAD_EXISTING_BACKUPS"; then
        return 0
    fi

    if [ ! -d "$session_dir" ]; then
        log "WARN: Cannot offload ${project}/${label}: local session directory not found at ${session_dir}"
        return 1
    fi

    if [ ! -d "$OBJECT_STORE_MOUNT" ]; then
        log "WARN: Cannot offload ${project}/${label}: object-store mount not found at ${OBJECT_STORE_MOUNT}"
        return 1
    fi

    local object_session="${OBJECT_STORE_LINK_PREFIX}/${project}/${label}"
    if [ ! -d "$object_session" ]; then
        log "WARN: Cannot offload ${project}/${label}: object-store session path missing at ${object_session}"
        return 1
    fi

    local offloaded=0
    local skipped=0
    local failed=0
    local file rel object_file local_size object_size tmp_link

    while IFS= read -r -d '' file; do
        if should_keep_local "$file"; then
            skipped=$((skipped + 1))
            continue
        fi

        rel="${file#${session_dir}/}"
        local_size=$(stat -c '%s' "$file")
        object_file=$(resolve_object_file "$object_session" "$label" "$rel" "$local_size" || true)

        if [ -z "$object_file" ]; then
            log "WARN: Cannot offload ${file}: no matching object under ${object_session}"
            failed=$((failed + 1))
            continue
        fi

        if truthy "$OFFLOAD_DRY_RUN"; then
            log "DRY-RUN: would replace ${file} -> ${object_file}"
            offloaded=$((offloaded + 1))
            continue
        fi

        tmp_link="${file}.offload-link.$$"
        if ln -s "$object_file" "$tmp_link" && mv -Tf "$tmp_link" "$file"; then
            offloaded=$((offloaded + 1))
        else
            rm -f "$tmp_link"
            log "WARN: Failed to replace ${file} with symlink"
            failed=$((failed + 1))
        fi
    done < <(find "$session_dir" -type f -print0)

    log "Offload ${project}/${label}: ${offloaded} symlinked, ${skipped} kept local, ${failed} failures"
    [ "$failed" -eq 0 ]
}

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

    if [ -n "$SESSION_ID_FILTER" ]; then
        FILTER_TEXT="${session_id} ${project}/${label} ${label}"
        if ! printf '%s\n' "$FILTER_TEXT" | grep -Eq "$SESSION_ID_FILTER"; then
            continue
        fi
    fi

    # Check if already backed up by looking for a marker file in GCS
    if gsutil -q stat "${GCS_PATH}/.backup_complete" 2>/dev/null; then
        log "SKIP: ${project}/${label} already backed up"
        if truthy "$OFFLOAD_EXISTING_BACKUPS"; then
            if offload_session "$project" "$label"; then
                :
            else
                FAILED=$((FAILED + 1))
            fi
        fi
        continue
    fi

    SESSION_WORK_DIR="${WORK_DIR}/${session_id}"
    EXTRACT_DIR="${SESSION_WORK_DIR}/extract"
    mkdir -p "$EXTRACT_DIR"

    SCANS_JSON="${SESSION_WORK_DIR}/scans.json"
    SCAN_FILES_JSON="${SESSION_WORK_DIR}/scan-files.json"
    EXP_FILES_JSON="${SESSION_WORK_DIR}/experiment-files.json"
    SCAN_COUNT=0
    SCAN_FILE_COUNT=0
    EXP_FILE_COUNT=0
    SESSION_FAILED=0

    if curl -sf -b "JSESSIONID=${JSESSION}" \
        -o "$SCANS_JSON" \
        "${XNAT_URL}/data/experiments/${session_id}/scans?format=json"; then
        SCAN_COUNT=$(json_count "$SCANS_JSON")
    else
        log "WARN: Failed to list scans for ${project}/${label} (${session_id})"
        SESSION_FAILED=1
    fi

    if [ "$SCAN_COUNT" -gt 0 ]; then
        if curl -sf -b "JSESSIONID=${JSESSION}" \
            -o "$SCAN_FILES_JSON" \
            "${XNAT_URL}/data/experiments/${session_id}/scans/ALL/files?format=json"; then
            SCAN_FILE_COUNT=$(json_count "$SCAN_FILES_JSON")
        else
            log "WARN: Failed to list scan files for ${project}/${label} (${session_id})"
            SESSION_FAILED=1
        fi
    fi

    if curl -sf -b "JSESSIONID=${JSESSION}" \
        -o "$EXP_FILES_JSON" \
        "${XNAT_URL}/data/experiments/${session_id}/files?format=json"; then
        EXP_FILE_COUNT=$(json_count "$EXP_FILES_JSON")
    else
        log "WARN: Failed to list experiment files for ${project}/${label} (${session_id})"
        SESSION_FAILED=1
    fi

    FILE_COUNT=$((SCAN_FILE_COUNT + EXP_FILE_COUNT))
    if [ "$FILE_COUNT" -eq 0 ]; then
        log "SKIP: ${project}/${label} (${session_id}) has no files to back up"
        rm -rf "$SESSION_WORK_DIR"
        if [ "$SESSION_FAILED" -gt 0 ]; then
            FAILED=$((FAILED + 1))
        fi
        continue
    fi

    if [ "$SESSION_FAILED" -gt 0 ]; then
        log "WARN: Skipping ${project}/${label} because file listing was incomplete"
        FAILED=$((FAILED + 1))
        rm -rf "$SESSION_WORK_DIR"
        continue
    fi

    log "Downloading ${project}/${label} (${session_id}, ${SCAN_FILE_COUNT} scan files, ${EXP_FILE_COUNT} experiment files)..."

    if [ "$SCAN_FILE_COUNT" -gt 0 ]; then
        if ! download_zip \
            "${project}/${label} scan files" \
            "${XNAT_URL}/data/experiments/${session_id}/scans/ALL/files?format=zip" \
            "${SESSION_WORK_DIR}/scan-files.zip" \
            "$EXTRACT_DIR"; then
            SESSION_FAILED=1
        fi
    fi

    if [ "$EXP_FILE_COUNT" -gt 0 ]; then
        if ! download_zip \
            "${project}/${label} experiment files" \
            "${XNAT_URL}/data/experiments/${session_id}/files?format=zip" \
            "${SESSION_WORK_DIR}/experiment-files.zip" \
            "$EXTRACT_DIR"; then
            SESSION_FAILED=1
        fi
    fi

    if [ "$SESSION_FAILED" -gt 0 ]; then
        FAILED=$((FAILED + 1))
        rm -rf "$SESSION_WORK_DIR"
        continue
    fi

    log "Syncing ${project}/${label} -> ${GCS_PATH}"
    if gsutil -m -q rsync -r "$EXTRACT_DIR" "${GCS_PATH}/" 2>&1; then
        if truthy "$OFFLOAD_AFTER_BACKUP"; then
            if ! offload_session "$project" "$label"; then
                FAILED=$((FAILED + 1))
                rm -rf "$SESSION_WORK_DIR"
                continue
            fi
        fi
        # Write marker so we skip on next run. When offload is enabled, this is
        # written only after local symlink replacement has also succeeded.
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" | gsutil -q cp - "${GCS_PATH}/.backup_complete"
        BACKED_UP=$((BACKED_UP + 1))
        log "OK: ${project}/${label} backed up"
    else
        log "WARN: Failed to upload ${project}/${label} to GCS"
        FAILED=$((FAILED + 1))
    fi

    # Clean up temp files
    rm -rf "$SESSION_WORK_DIR"
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
