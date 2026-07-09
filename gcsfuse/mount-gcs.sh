#!/bin/bash
set -euo pipefail

GCS_BUCKET="${GCS_BUCKET:?GCS_BUCKET must be set}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/object-store}"
GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:?GOOGLE_APPLICATION_CREDENTIALS must be set}"
GCSFUSE_FLAGS=(
  "--implicit-dirs"
  "--file-mode=0444"
  "--dir-mode=0555"
  "--uid=0"
  "--gid=0"
  "--o=ro,allow_other"
  "--key-file=${GOOGLE_APPLICATION_CREDENTIALS}"
)

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

mkdir -p "$MOUNT_POINT"

is_gcsfuse_mounted() {
  findmnt -T "$MOUNT_POINT" -n -o FSTYPE 2>/dev/null | grep -Eq '(^|[.])fuse'
}

if is_gcsfuse_mounted; then
  log "${MOUNT_POINT} is already mounted with FUSE"
else
  log "Mounting gs://${GCS_BUCKET} at ${MOUNT_POINT}"
  gcsfuse "${GCSFUSE_FLAGS[@]}" "$GCS_BUCKET" "$MOUNT_POINT"
fi

cleanup() {
  log "Unmounting ${MOUNT_POINT}"
  fusermount3 -u "$MOUNT_POINT" 2>/dev/null || fusermount -u "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup INT TERM

while is_gcsfuse_mounted; do
  sleep 30
done

log "${MOUNT_POINT} is no longer mounted"
