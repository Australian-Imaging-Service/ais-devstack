#!/bin/bash
# ============================================================================
# JupyterHub + XNAT integration — master install (k3s / MicroK8s)
# ----------------------------------------------------------------------------
# HYBRID flow after the neurodesk-chart consolidation:
#   • Infrastructure installs the SAME way as before — Longhorn (2-), the
#     jupyter NFS shared-workspace PV/PVC (3-/4-), and monitoring (5-).
#     (NFS server + ingress + cert-manager + the XNAT server come from
#     ../scripts/ and are assumed already installed.)
#   • The JupyterHub APPLICATION LAYER (JupyterHub + CVMFS + smarter-device-
#     manager + Security Profiles Operator + XNAT notebook extension) is now ONE
#     Helm chart, driven by 6-install-neurodesk.sh -> neurodesk/install.sh
#     (replaces the old 5/6/8/9/10 scripts + cvmfs_mount/ + security/ + squid/).
#   • 7-xnat-jupyter-plugin.sh refreshes the XNAT server-side plugin (optional).
# ============================================================================
set -e

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_environment() {
    if command -v microk8s &> /dev/null && microk8s status &> /dev/null; then echo "microk8s"
    elif command -v k3s &> /dev/null || [ -f /etc/rancher/k3s/k3s.yaml ]; then echo "k3s"
    elif command -v kubectl &> /dev/null && kubectl get nodes &> /dev/null; then echo "kubectl"
    else echo "none"; fi
}
ENV_TYPE=$(detect_environment)
if [ "$ENV_TYPE" = "microk8s" ]; then KUBECTL="microk8s kubectl"; HELM="microk8s helm"
elif [ "$ENV_TYPE" = "k3s" ] || [ "$ENV_TYPE" = "kubectl" ]; then KUBECTL="kubectl"; HELM="helm"
else echo -e "${RED}No Kubernetes environment detected. Install k3s/MicroK8s first.${NC}"; exit 1; fi

wait_for_user() { echo ""; echo -e "${YELLOW}$1${NC}"; read -p "Press ENTER to continue or Ctrl+C to abort..."; }
check_status() { if [ "$1" -eq 0 ]; then echo -e "${GREEN}Done${NC}"; else echo -e "${RED}Failed${NC}"; exit 1; fi; }

echo -e "${BLUE}=========================================="
echo "  JUPYTERHUB-XNAT INTEGRATION — install"
echo "  JupyterHub layer = neurodesk Helm chart"
echo "==========================================${NC}"

# ---- pre-flight ------------------------------------------------------------
echo -e "${BLUE}[Pre-flight]${NC}"
$KUBECTL get nodes >/dev/null || { echo -e "${RED}Cannot reach cluster${NC}"; exit 1; }
if ! $KUBECTL get pods -n ais-xnat 2>/dev/null | grep -q xnat-web; then
    echo -e "${YELLOW}XNAT server not found in ais-xnat. Install it first: ../scripts/install.sh${NC}"
fi
if ! $KUBECTL get pods -n storage 2>/dev/null | grep -q nfs-server; then
    echo -e "${YELLOW}NFS server not found in 'storage'. Install it first (../scripts/install.sh) — steps 3/4 need it.${NC}"
fi
echo -e "${GREEN}Cluster reachable${NC}"
wait_for_user "Ready to begin?"

# ---- 1. (optional) clean a previous install --------------------------------
echo -e "${BLUE}[1/6] Cleanup (optional)${NC}"
read -p "Run full cleanup (1-cleanup.sh removes JH layer + Longhorn + monitoring)? (y/N): " doclean
if [[ "$doclean" =~ ^[Yy]$ ]]; then chmod +x "$SCRIPT_DIR/1-cleanup.sh"; "$SCRIPT_DIR/1-cleanup.sh"; check_status $?; fi

# ---- 2. Longhorn (infra) ---------------------------------------------------
echo -e "${BLUE}[2/6] Longhorn storage${NC}"
chmod +x "$SCRIPT_DIR/2-install-longhorn.sh"; "$SCRIPT_DIR/2-install-longhorn.sh"; check_status $?

# ---- 3. NFS shared workspace PV/PVC (jupyter xnat-gpfs) ---------------------
echo -e "${BLUE}[3/6] NFS shared workspace (jupyter/xnat-gpfs, bridges XNAT <-> notebooks)${NC}"
$KUBECTL create namespace jupyter 2>/dev/null || true
$KUBECTL apply -f "$SCRIPT_DIR/3-nfs-pv.yaml"
$KUBECTL apply -f "$SCRIPT_DIR/4-nfs-pvc.yaml"
$KUBECTL wait --for=jsonpath='{.status.phase}'=Bound pvc/xnat-gpfs -n jupyter --timeout=60s 2>/dev/null || \
  echo -e "${YELLOW}  (xnat-gpfs not Bound yet — ensure nfs-server is running)${NC}"
check_status $?

# ---- 4. Monitoring (infra) -------------------------------------------------
echo -e "${BLUE}[4/6] Prometheus monitoring stack${NC}"
chmod +x "$SCRIPT_DIR/5-monitoring.sh"; "$SCRIPT_DIR/5-monitoring.sh"; check_status $?
wait_for_user "Infra ready. Install the JupyterHub layer (neurodesk chart)?"

# ---- 5. JupyterHub application layer = ONE chart (via the wrapper) ----------
echo -e "${BLUE}[5/6] JupyterHub layer via neurodesk chart"
echo "      (JupyterHub + CVMFS + smarter-device-manager + SPO + XNAT extension)${NC}"
if [ ! -f "$SCRIPT_DIR/neurodesk/values-devstack.yaml" ]; then
    echo -e "${RED}Missing jupyterhub/neurodesk/values-devstack.yaml${NC}"
    echo "Create it: cp neurodesk/values-devstack.yaml.template neurodesk/values-devstack.yaml  (then fill in secrets)"
    exit 1
fi
chmod +x "$SCRIPT_DIR/6-install-neurodesk.sh"; "$SCRIPT_DIR/6-install-neurodesk.sh"; check_status $?
echo "Waiting for JupyterHub layer to become ready..."
$KUBECTL wait --for=condition=ready pod -l component=hub -n jupyter --timeout=300s 2>/dev/null || true

# ---- 6. XNAT server-side plugin (optional) ---------------------------------
echo -e "${BLUE}[6/6] XNAT JupyterHub plugin (server-side, optional)${NC}"
read -p "Install/refresh the XNAT-side JupyterHub plugin? (y/N): " doxnat
if [[ "$doxnat" =~ ^[Yy]$ ]]; then chmod +x "$SCRIPT_DIR/7-xnat-jupyter-plugin.sh"; "$SCRIPT_DIR/7-xnat-jupyter-plugin.sh" || true; fi

# ---- verify ----------------------------------------------------------------
echo -e "${BLUE}=========================================="
echo "  VERIFY"
echo "==========================================${NC}"
$KUBECTL get pods -n jupyter
echo ""; echo "AppArmor profile:"; $KUBECTL get apparmorprofile -n jupyter 2>/dev/null || echo "  (none)"
echo ""; echo -e "${GREEN}INSTALLATION COMPLETE${NC}"
echo "JupyterHub:  https://<domain>/jupyter      (set in neurodesk/values-devstack.yaml)"
echo "Uninstall the JupyterHub layer:  ./UNINSTALL.sh"
echo "Next: configure the XNAT JupyterHub plugin (see XNAT-CONFIGURATION.md)."
