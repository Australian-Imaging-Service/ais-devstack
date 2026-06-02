#!/bin/bash
# ============================================================================
# UNINSTALL.sh — master uninstall for the JupyterHub layer.
# ----------------------------------------------------------------------------
# Default: remove ONLY the JupyterHub application layer (the neurodesk chart)
# and its cluster-scoped leftovers, KEEPING all infrastructure and XNAT
# (Longhorn, NFS, ingress, cert-manager, monitoring, the XNAT server).
# This delegates to jupyterhub/neurodesk/uninstall.sh.
#
# For a FULL teardown that also removes Longhorn + monitoring + the jupyter
# namespace (everything the JupyterHub side installed), run 1-cleanup.sh
# instead — it does NOT touch XNAT but does remove shared infra.
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "${BLUE}=========================================="
echo "  JupyterHub layer — uninstall (neurodesk chart)"
echo "==========================================${NC}"
echo -e "${YELLOW}Removes the neurodesk Helm release + its cluster-scoped SPO objects."
echo -e "Keeps infrastructure (Longhorn/NFS/ingress/cert-manager/monitoring) and XNAT.${NC}"
echo ""
read -p "Continue? (y/N): " ok
[[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

chmod +x "$SCRIPT_DIR/neurodesk/uninstall.sh"
"$SCRIPT_DIR/neurodesk/uninstall.sh"

echo ""
echo -e "${GREEN}JupyterHub layer uninstalled.${NC}"
echo "For a full infra teardown (Longhorn + monitoring + namespaces, NOT XNAT): ./1-cleanup.sh"
