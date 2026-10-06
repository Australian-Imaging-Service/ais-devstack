#!/bin/bash
# JupyterHub Uninstallation Script
# Wrapper for jupyterhub/1-cleanup.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
JUPYTERHUB_DIR="$BASE_DIR/jupyterhub"

echo "=========================================="
echo "   JupyterHub Uninstallation"
echo "=========================================="
echo ""

if [ ! -f "$JUPYTERHUB_DIR/1-cleanup.sh" ]; then
    echo "Error: Cleanup script not found at $JUPYTERHUB_DIR/1-cleanup.sh"
    exit 1
fi

chmod +x "$JUPYTERHUB_DIR/1-cleanup.sh"
cd "$JUPYTERHUB_DIR"
./1-cleanup.sh
