#!/bin/bash
# Install JupyterHub with XNAT integration
# Supports both MicroK8s and k3s environments
set -e

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect environment and set commands
detect_environment() {
    if command -v microk8s &> /dev/null && microk8s status &> /dev/null; then
        echo "microk8s"
    elif command -v k3s &> /dev/null || [ -f /etc/rancher/k3s/k3s.yaml ]; then
        echo "k3s"
    elif command -v kubectl &> /dev/null && kubectl get nodes &> /dev/null; then
        echo "kubectl"
    else
        echo "none"
    fi
}

ENV_TYPE=$(detect_environment)

if [ "$ENV_TYPE" = "microk8s" ]; then
    KUBECTL="microk8s kubectl"
    HELM="microk8s helm"
    ENV_NAME="MicroK8s"
elif [ "$ENV_TYPE" = "k3s" ] || [ "$ENV_TYPE" = "kubectl" ]; then
    KUBECTL="kubectl"
    HELM="helm"
    ENV_NAME="k3s"
else
    echo -e "${RED}No Kubernetes environment detected.${NC}"
    echo "Please install k3s or MicroK8s first."
    exit 1
fi

echo "=========================================="
echo "STEP 2: Installing JupyterHub"
echo "Detected environment: ${ENV_NAME}"
echo "=========================================="

# Create jupyter namespace
echo -e "${BLUE}[1/6] Creating jupyter namespace...${NC}"
$KUBECTL create namespace jupyter 2>/dev/null || echo "Namespace already exists"

# Apply NFS PVs and PVCs
echo -e "${BLUE}[2/6] Creating NFS PersistentVolumes and Claims...${NC}"
$KUBECTL apply -f "$SCRIPT_DIR/3-nfs-pv.yaml"
$KUBECTL apply -f "$SCRIPT_DIR/4-nfs-pvc.yaml"

# Wait for PVCs to bind
echo "Waiting for PVCs to bind..."
$KUBECTL wait --for=jsonpath='{.status.phase}'=Bound pvc/xnat-gpfs -n jupyter --timeout=60s

# Apply XNAT Upload Extension ConfigMap BEFORE installing JupyterHub
echo -e "${BLUE}[3/6] Applying XNAT Upload Extension ConfigMap...${NC}"
$KUBECTL apply -f "$SCRIPT_DIR/10-xnat-upload-extension.yaml"
echo "XNAT Upload Extension ConfigMap created"

# Add JupyterHub Helm repo
echo -e "${BLUE}[4/6] Adding JupyterHub Helm repository...${NC}"
$HELM repo add jupyterhub https://hub.jupyter.org/helm-chart/
$HELM repo update

# Install JupyterHub
echo -e "${BLUE}[5/6] Installing JupyterHub...${NC}"
$HELM upgrade --install jupyterhub jupyterhub/jupyterhub \
  --namespace jupyter \
  --version 4.3.1 \
  --values "$SCRIPT_DIR/5-jupyterhub-values.yaml" \
  --timeout 10m

# Wait for JupyterHub to be ready
echo -e "${BLUE}[6/6] Waiting for JupyterHub pods to be ready...${NC}"
$KUBECTL wait --for=condition=ready pod -l app=jupyterhub -n jupyter --timeout=300s 2>/dev/null || true
$KUBECTL wait --for=condition=ready pod -l component=hub -n jupyter --timeout=300s
$KUBECTL wait --for=condition=ready pod -l component=proxy -n jupyter --timeout=300s

echo ""
echo -e "${GREEN}=========================================="
echo "JupyterHub Installation Complete"
echo "==========================================${NC}"
echo ""
echo "Verify installation:"
echo "  $KUBECTL get pods -n jupyter"
echo "  $KUBECTL get svc -n jupyter"
echo "  $KUBECTL get pvc -n jupyter"
echo ""
echo "JupyterHub URLs:"
echo "  External: http://xnat-test.ssdsorg.cloud.edu.au/jupyter"
echo "  Internal API: http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api"
echo ""
echo "XNAT Plugin Configuration:"
echo "  JupyterHub host URL: http://xnat-test.ssdsorg.cloud.edu.au/"
echo "  JupyterHub API URL: http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api"
echo "  Service Token: <jupyter-token>"
echo "  Note: Update XNAT's config to match your domain and token."
echo ""
