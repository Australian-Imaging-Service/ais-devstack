#!/bin/bash
# 6-cvmfs-mounts.sh - Setup CVMFS and Metrics for XNAT JupyterHub
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
    KUBELET_PATH="/var/snap/microk8s/common/var/lib/kubelet"
elif [ "$ENV_TYPE" = "k3s" ] || [ "$ENV_TYPE" = "kubectl" ]; then
    KUBECTL="kubectl"
    HELM="helm"
    ENV_NAME="k3s"
    KUBELET_PATH="/var/lib/kubelet"
else
    echo -e "${RED}No Kubernetes environment detected.${NC}"
    exit 1
fi

echo "=========================================="
echo "Setting up CVMFS Mounts and Metrics"
echo "Environment: ${ENV_NAME}"
echo "=========================================="

# Create namespace for mounts
echo -e "${BLUE}[1/9] Creating mounts and jupyter namespace...${NC}"
$KUBECTL create namespace mounts --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL create namespace jupyter 2>/dev/null || echo "Namespace already exists"

# Add CVMFS CSI Helm repository
echo -e "${BLUE}[2/9] Adding CVMFS CSI Helm repository...${NC}"
$HELM repo add cvmfs-csi https://registry.cern.ch/chartrepo/cern 2>/dev/null || true
$HELM repo add smarter-device-manager https://smarter-project.github.io/smarter-device-manager 2>/dev/null || true
$HELM repo update

# Label nodes for smarter-device-manager (enables /dev/fuse access)
echo -e "${BLUE}[3/9] Labeling nodes for device manager...${NC}"
$KUBECTL get nodes -o name | while read node; do
  $KUBECTL label $node smarter-device-manager=enabled --overwrite
done

# Install smarter-device-manager for /dev/fuse access
echo -e "${BLUE}[4/9] Installing smarter-device-manager...${NC}"
$HELM upgrade --install smarter-device-manager smarter-device-manager/smarter-device-manager \
  -n mounts \
  --set config[0].devicematch="^fuse$" \
  --set config[0].nummaxdevices=20 \
  --wait

# Install CVMFS CSI driver
echo -e "${BLUE}[5/9] Installing CVMFS CSI driver...${NC}"
$HELM upgrade --install cvmfs-csi cvmfs-csi/cvmfs-csi \
  -n mounts \
  -f "$SCRIPT_DIR/cvmfs_mount/values.yaml" \
  --set kubeletDirectory="$KUBELET_PATH" \
  --wait

# Create CVMFS PVC in jupyter namespace
echo -e "${BLUE}[6/9] Creating CVMFS PVC...${NC}"
$KUBECTL apply -f "$SCRIPT_DIR/cvmfs_mount/pvc.yaml"

# Deploy CVMFS Trace Parser components
echo -e "${BLUE}[7/9] Deploying CVMFS metrics RBAC...${NC}"
$KUBECTL apply -f "$SCRIPT_DIR/cvmfs_mount/templates/file-retriever-rbac.yaml"

echo -e "${BLUE}[8/9] Deploying CVMFS metrics ConfigMaps and Service...${NC}"
$KUBECTL apply -f "$SCRIPT_DIR/cvmfs_mount/templates/trace-parser-config.yaml"
$KUBECTL apply -f "$SCRIPT_DIR/cvmfs_mount/templates/parser-script-configmap.yaml"
$KUBECTL apply -f "$SCRIPT_DIR/cvmfs_mount/templates/trace-parser-service.yaml"

echo -e "${BLUE}[9/9] Deploying CVMFS Trace Parser...${NC}"
$KUBECTL apply -f "$SCRIPT_DIR/cvmfs_mount/templates/trace-parser-deployment.yaml"

# Apply ServiceMonitor only if CRD exists (requires Prometheus to be installed first)
if $KUBECTL get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
    echo "Applying ServiceMonitor for Prometheus scraping..."
    $KUBECTL apply -f "$SCRIPT_DIR/cvmfs_mount/templates/servicemonitor.yaml"
else
    echo -e "${YELLOW}Note: ServiceMonitor CRD not found (Prometheus not installed yet).${NC}"
    echo "The ServiceMonitor will be applied automatically when you run 7-monitoring.sh"
fi

echo ""
echo -e "${GREEN}CVMFS and Metrics setup completed successfully${NC}"
echo ""
echo "Verify installation:"
echo "  $KUBECTL get pods -n mounts"
echo "  $KUBECTL get pvc -n jupyter cvmfs"
echo "  $KUBECTL get svc -n mounts cvmfs-metrics"
echo ""
echo "Test metrics endpoint:"
echo "  $KUBECTL port-forward -n mounts svc/cvmfs-metrics 9002:9002"
echo "  curl http://localhost:9002/metrics"
echo ""
echo "Note: Install the monitoring stack (7-monitoring.sh) to enable Prometheus scraping."
