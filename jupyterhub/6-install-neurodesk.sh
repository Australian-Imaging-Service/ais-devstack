#!/usr/bin/env bash
# ============================================================================
# 6-install-neurodesk.sh — JupyterHub application layer (the neurodesk chart).
# ----------------------------------------------------------------------------
# Thin wrapper at the jupyterhub/ level that drives everything under
# jupyterhub/neurodesk/ (the single consolidated chart that replaced the old
# 5/6/8/9/10 scripts + cvmfs_mount/ + security/ + squid/).
#
# It just delegates to jupyterhub/neurodesk/install.sh — all env overrides
# (NAMESPACE, RELEASE, CHART_REPO, CHART_REF, CHART_PATH, VALUES) pass straight
# through. Run `./6-install-neurodesk.sh` after the infra steps (2-longhorn,
# 3-nfs-pv, 4-nfs-pvc, 5-monitoring).
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/neurodesk/install.sh" "$@"
