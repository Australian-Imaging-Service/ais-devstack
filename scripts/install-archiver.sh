#!/bin/bash
# XNAT GCS Archiver Setup Script
# Creates secrets, builds the archiver/FUSE containers, and deploys the
# CronJob plus read-only GCS FUSE mount for XNAT archive offload.
set -e

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

check_status() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}Done${NC}"
    else
        echo -e "${RED}Failed${NC}"
        exit 1
    fi
}

echo -e "${BLUE}"
echo "=========================================="
echo "   XNAT GCS Archiver Setup"
echo "=========================================="
echo -e "${NC}"

# Pre-flight checks
echo -e "${BLUE}[Pre-flight Checks]${NC}"
for cmd in kubectl docker; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}${cmd} not found${NC}"
        exit 1
    fi
    echo -e "${GREEN}${cmd} found${NC}"
done

if ! kubectl get nodes &>/dev/null; then
    echo -e "${RED}Cannot connect to k3s cluster${NC}"
    exit 1
fi
echo -e "${GREEN}k3s cluster accessible${NC}"
echo ""

# ── Step 1: Gather configuration ───────────────────────────────────
echo -e "${BLUE}=========================================="
echo "   Configuration"
echo "==========================================${NC}"
echo ""

# GCS Bucket
read -p "GCS bucket name [xnat-lucas-archive]: " GCS_BUCKET
GCS_BUCKET=${GCS_BUCKET:-xnat-lucas-archive}

# Service Account key file
while true; do
    read -p "Path to GCP Service Account JSON key file: " SA_KEY_PATH
    if [ -f "$SA_KEY_PATH" ]; then
        break
    fi
    echo -e "${RED}File not found: ${SA_KEY_PATH}${NC}"
done

# Extract the key filename for the secret item mapping
SA_KEY_FILENAME=$(basename "$SA_KEY_PATH")

# XNAT admin credentials
read -p "XNAT admin username [admin]: " XNAT_USER
XNAT_USER=${XNAT_USER:-admin}
read -sp "XNAT admin password: " XNAT_PASS
echo ""

if [ -z "$XNAT_PASS" ]; then
    echo -e "${RED}XNAT password cannot be empty${NC}"
    exit 1
fi

# DB password (optional, for pg_dump)
VALUES_FILE="$BASE_DIR/manifests/values.yaml"
DEFAULT_DB_PASS=$(grep -A5 "postgresql:" "$VALUES_FILE" | grep "password:" | head -1 | awk '{print $2}')
read -sp "PostgreSQL password for DB backup [$DEFAULT_DB_PASS]: " DB_PASS
echo ""
DB_PASS=${DB_PASS:-$DEFAULT_DB_PASS}

# Container registry
read -p "Container image name [xnat-gcs-archiver:latest]: " IMAGE_NAME
IMAGE_NAME=${IMAGE_NAME:-xnat-gcs-archiver:latest}

echo ""
echo -e "${YELLOW}Configuration:${NC}"
echo "  GCS Bucket:     ${GCS_BUCKET}"
echo "  SA Key File:    ${SA_KEY_PATH}"
echo "  XNAT User:      ${XNAT_USER}"
echo "  Image:          ${IMAGE_NAME}"
echo ""
read -p "Proceed with installation? (Y/n): " proceed
if [[ "$proceed" =~ ^[Nn]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi
echo ""

# ── Step 2: Create Kubernetes Secrets ──────────────────────────────
echo -e "${BLUE}[Step 1/5] Creating Kubernetes Secrets...${NC}"

kubectl create namespace ais-xnat 2>/dev/null || true

# GCS Service Account key — store with the original filename
kubectl -n ais-xnat delete secret gcs-sa-key 2>/dev/null || true
kubectl -n ais-xnat create secret generic gcs-sa-key \
    --from-file="$SA_KEY_FILENAME"="$SA_KEY_PATH"

# Update the CronJob manifest to reference the correct key filename
CRONJOB_FILE="$BASE_DIR/manifests/archive-cronjob.yaml"
GCS_FUSE_FILE="$BASE_DIR/manifests/gcs-fuse-mount.yaml"
sed -i "s|key: .*\.json|key: ${SA_KEY_FILENAME}|" "$CRONJOB_FILE"
sed -i "s|key: .*\.json|key: ${SA_KEY_FILENAME}|" "$GCS_FUSE_FILE"

# XNAT archiver credentials
kubectl -n ais-xnat delete secret xnat-archiver-creds 2>/dev/null || true
kubectl -n ais-xnat create secret generic xnat-archiver-creds \
    --from-literal=username="$XNAT_USER" \
    --from-literal=password="$XNAT_PASS" \
    --from-literal=db-password="$DB_PASS"

check_status $?

# ── Step 3: Build and load container image ────────────────────────
echo -e "${BLUE}[Step 2/5] Building archiver container image...${NC}"

docker build -t "$IMAGE_NAME" "$BASE_DIR/archiver/"

# For k3s, import the image directly
echo "Importing image into k3s..."
docker save "$IMAGE_NAME" | sudo k3s ctr images import -
check_status $?

# ── Step 4: Build FUSE mount image ────────────────────────────────
echo -e "${BLUE}[Step 3/5] Building GCS FUSE mount image...${NC}"

docker build -t xnat-gcsfuse:latest "$BASE_DIR/gcsfuse/"

echo "Importing image into k3s..."
docker save xnat-gcsfuse:latest | sudo k3s ctr images import -
check_status $?

# ── Step 5: Deploy CronJob and FUSE mount ─────────────────────────
echo -e "${BLUE}[Step 4/5] Deploying archiver CronJob and GCS FUSE mount...${NC}"

# Update bucket name in CronJob if different from default
if [ "$GCS_BUCKET" != "xnat-lucas-archive" ]; then
    sed -i "s/value: \"xnat-lucas-archive\"/value: \"${GCS_BUCKET}\"/" "$CRONJOB_FILE"
    sed -i "s/value: \"xnat-lucas-archive\"/value: \"${GCS_BUCKET}\"/" "$GCS_FUSE_FILE"
fi

# Update image name if different from default
if [ "$IMAGE_NAME" != "xnat-gcs-archiver:latest" ]; then
    sed -i "s|image: xnat-gcs-archiver:latest|image: ${IMAGE_NAME}|" "$CRONJOB_FILE"
fi

kubectl apply -f "$CRONJOB_FILE"
kubectl apply -f "$GCS_FUSE_FILE"
sudo mkdir -p /data/xnat
sudo ln -sfn /srv/xnat-local-storage/gpfs/object-store /data/xnat/object-store
check_status $?

# ── Verify ────────────────────────────────────────────────────────
echo -e "${BLUE}[Step 5/5] Verifying deployment...${NC}"

kubectl -n ais-xnat get cronjob xnat-gcs-archiver
kubectl -n ais-xnat get daemonset xnat-gcs-fuse
check_status $?

# ── Done ──────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}=========================================="
echo "   XNAT GCS Archiver Installed!"
echo "==========================================${NC}"
echo ""
echo "The archiver CronJob runs daily at 2:00 AM and will:"
echo "  1. Download all XNAT sessions via REST API and upload to gs://${GCS_BUCKET}/sessions/"
echo "  2. Dump PostgreSQL to gs://${GCS_BUCKET}/db-backups/"
echo "  3. Replace newly backed-up local archive files with verified symlinks into the GCS FUSE mount"
echo ""
echo "Manual trigger:"
echo "  kubectl -n ais-xnat create job --from=cronjob/xnat-gcs-archiver xnat-manual-\$(date +%s)"
echo ""
echo "Check status:"
echo "  kubectl -n ais-xnat get jobs"
echo "  kubectl -n ais-xnat logs job/<job-name>"
echo ""
