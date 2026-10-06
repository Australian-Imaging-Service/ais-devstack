#!/bin/bash
# 7-monitoring.sh - Setup Prometheus Stack for CVMFS Metrics Monitoring
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
    exit 1
fi

echo "=========================================="
echo "Setting up Prometheus Monitoring Stack"
echo "Environment: ${ENV_NAME}"
echo "=========================================="

# Create monitoring namespace
echo -e "${BLUE}[1/4] Creating monitoring namespace...${NC}"
$KUBECTL create namespace monitoring --dry-run=client -o yaml | $KUBECTL apply -f -

# Add Prometheus Community Helm repository
echo -e "${BLUE}[2/4] Adding Prometheus Community Helm repository...${NC}"
$HELM repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
$HELM repo update

# Install kube-prometheus-stack
echo -e "${BLUE}[3/4] Installing kube-prometheus-stack...${NC}"
$HELM upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f "$SCRIPT_DIR/monitoring/values.yaml" \
  --wait --timeout 10m

# Verify installation
echo -e "${BLUE}[4/4] Verifying installation...${NC}"
$KUBECTL get pods -n monitoring

# Apply CVMFS ServiceMonitor if CVMFS is already installed
if [ -f "$SCRIPT_DIR/cvmfs_mount/templates/servicemonitor.yaml" ] && \
   $KUBECTL get namespace mounts &>/dev/null && \
   $KUBECTL get svc cvmfs-metrics -n mounts &>/dev/null; then
    echo ""
    echo "CVMFS detected - applying ServiceMonitor for metrics scraping..."
    $KUBECTL apply -f "$SCRIPT_DIR/cvmfs_mount/templates/servicemonitor.yaml" || \
        echo -e "${YELLOW}Note: Could not apply CVMFS ServiceMonitor${NC}"
fi

echo ""
echo -e "${GREEN}Prometheus Monitoring Stack installed successfully${NC}"
echo ""
echo "Access Grafana:"
echo "  URL: http://<node-ip>:31000"
echo "  Default credentials: admin / admin"
echo ""
echo "Verify Prometheus targets:"
echo "  $KUBECTL port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo "  Then open: http://localhost:9090/targets"
echo ""
echo "The monitoring stack will automatically discover ServiceMonitors"
echo "from all namespaces, including CVMFS metrics from the 'mounts' namespace."
