#!/bin/bash
# Platform monitor setup
# Creates the SMTP secret, builds/imports the monitor image, and deploys the
# CronJob in manifests/platform-monitor.yaml.
#
# Non-interactive: SMTP_PASSWORD=... ./scripts/install-platform-monitor.sh
# The SMTP password is a Gmail app password; it lives only in the
# platform-monitor-smtp k8s secret, never in this repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
KUBECTL="sudo kubectl"

SMTP_USERNAME="${SMTP_USERNAME:-mail.neurodesk@gmail.com}"
ALERT_TO="${ALERT_TO:-$SMTP_USERNAME}"
IMAGE_NAME="${IMAGE_NAME:-xnat-platform-monitor:latest}"

# ── SMTP secret ─────────────────────────────────────────────────────
if [ -z "${SMTP_PASSWORD:-}" ]; then
    if $KUBECTL -n ais-xnat get secret platform-monitor-smtp &>/dev/null; then
        echo "Keeping existing platform-monitor-smtp secret (set SMTP_PASSWORD to rotate)."
    else
        read -rsp "Gmail app password for ${SMTP_USERNAME}: " SMTP_PASSWORD
        echo ""
    fi
fi

if [ -n "${SMTP_PASSWORD:-}" ]; then
    $KUBECTL -n ais-xnat delete secret platform-monitor-smtp 2>/dev/null || true
    $KUBECTL -n ais-xnat create secret generic platform-monitor-smtp \
        --from-literal=username="$SMTP_USERNAME" \
        --from-literal=password="$SMTP_PASSWORD" \
        --from-literal=to="$ALERT_TO"
    echo "Created platform-monitor-smtp secret."
fi

# ── Image ───────────────────────────────────────────────────────────
docker build -t "$IMAGE_NAME" "$BASE_DIR/monitoring/"
docker save "$IMAGE_NAME" | sudo k3s ctr images import -

# ── Deploy ──────────────────────────────────────────────────────────
$KUBECTL apply -f "$BASE_DIR/manifests/platform-monitor.yaml"
$KUBECTL -n ais-xnat get cronjob platform-monitor

echo ""
echo "Installed. Manual run:"
echo "  sudo kubectl -n ais-xnat create job --from=cronjob/platform-monitor platform-monitor-manual-\$(date +%s)"
