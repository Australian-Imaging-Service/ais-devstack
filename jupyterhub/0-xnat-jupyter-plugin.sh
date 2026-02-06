#!/bin/bash
set -e

echo "=========================================="
echo "Installing XNAT JupyterHub Plugin v1.3.3"
echo "=========================================="

# Get XNAT plugin JAR (v1.3.3)
echo "[1/4] Downloading plugin..."
wget https://github.com/NrgXnat/xnat-jupyterhub-plugin/releases/download/v1.3.3/xnat-jupyterhub-plugin-1.3.3.jar

# Get NFS server pod name dynamically
echo "[2/4] Finding NFS server pod..."
NFS_POD=$( kubectl -n storage get pods -l role=nfs-server -o jsonpath='{.items[0].metadata.name}')
echo "Found NFS pod: $NFS_POD"

# Copy to XNAT plugins directory
echo "[3/4] Copying plugin to NFS..."
 kubectl -n storage cp xnat-jupyterhub-plugin-1.3.3.jar \
  $NFS_POD:/exports/xnat/plugins/

# Restart XNAT to load plugin
# !!!!Beware this will wipe any ephemeral data in XNAT pods
echo "[4/4] Restarting XNAT..."
 kubectl -n ais-xnat rollout restart statefulset/xnat-web

# Wait for XNAT to be ready
 kubectl -n ais-xnat rollout status statefulset/xnat-web

echo ""
echo "✓ Plugin installed successfully"
echo "Login to XNAT and verify plugin in: Administer → Plugin Settings"