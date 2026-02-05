#!/bin/bash
# Install Longhorn for JupyterHub persistent storage
# Supports both MicroK8s and k3s environments
set -e

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
    LONGHORN_DATA_PATH="/var/snap/microk8s/common/var/lib/longhorn"
elif [ "$ENV_TYPE" = "k3s" ] || [ "$ENV_TYPE" = "kubectl" ]; then
    KUBECTL="kubectl"
    HELM="helm"
    ENV_NAME="k3s"
    KUBELET_PATH="/var/lib/kubelet"
    LONGHORN_DATA_PATH="/var/lib/longhorn"
else
    echo -e "${RED}No Kubernetes environment detected.${NC}"
    exit 1
fi

echo "=========================================="
echo "STEP 1: Installing Longhorn"
echo "Environment: ${ENV_NAME}"
echo "=========================================="

# Add Longhorn Helm repo
echo -e "${BLUE}[1/4] Adding Longhorn Helm repository...${NC}"
$HELM repo add longhorn https://charts.longhorn.io 2>/dev/null || true
$HELM repo update

# Create namespace
echo -e "${BLUE}[2/4] Creating longhorn-system namespace...${NC}"
$KUBECTL create namespace longhorn-system 2>/dev/null || echo "Namespace already exists"

# Install Longhorn with environment-specific settings
echo -e "${BLUE}[3/4] Installing Longhorn...${NC}"
$HELM upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --set defaultSettings.defaultDataPath="$LONGHORN_DATA_PATH" \
  --set csi.kubeletRootDir="$KUBELET_PATH" \
  --set persistence.defaultClass=true \
  --set persistence.defaultClassReplicaCount=1 \
  --set defaultSettings.replicaAutoBalance="least-effort"

# Wait for Longhorn to be ready
echo -e "${BLUE}[4/4] Waiting for Longhorn to be ready...${NC}"

# Wait for longhorn-manager pods
echo "Waiting for longhorn-manager..."
for i in {1..60}; do
    READY_COUNT=$($KUBECTL get pods -n longhorn-system -l app=longhorn-manager -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | grep -o "true" | wc -l)
    TOTAL_COUNT=$($KUBECTL get pods -n longhorn-system -l app=longhorn-manager --no-headers 2>/dev/null | wc -l)
    if [ "$READY_COUNT" -ge "$TOTAL_COUNT" ] && [ "$TOTAL_COUNT" -gt 0 ]; then
        echo "Longhorn manager is ready"
        break
    fi
    echo -n "."
    sleep 5
done
echo ""

# Wait for CSI driver components
echo "Waiting for Longhorn CSI components..."
sleep 10
$KUBECTL wait --for=condition=ready pod -l app=csi-attacher -n longhorn-system --timeout=60s 2>/dev/null || echo "CSI components starting..."

# Apply BackupTarget configuration
echo "Configuring Longhorn backup target..."
$KUBECTL apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: BackupTarget
metadata:
  name: default
  namespace: longhorn-system
spec:
  backupTargetURL: ""
  credentialSecret: ""
  pollInterval: "300s"
EOF

# Wait for BackupTarget to be created
echo "Waiting for BackupTarget to be ready..."
$KUBECTL wait --for=jsonpath='{.status.available}'=true \
  backuptarget/default -n longhorn-system --timeout=60s 2>/dev/null || echo "BackupTarget created"

# Restart Longhorn Manager to pick up the configuration
echo "Restarting Longhorn manager..."
$KUBECTL rollout restart daemonset longhorn-manager -n longhorn-system

# Wait for rollout to complete
$KUBECTL rollout status daemonset longhorn-manager -n longhorn-system --timeout=300s

echo ""
echo -e "${GREEN}=========================================="
echo "Longhorn Installation Complete"
echo "==========================================${NC}"
echo ""
echo "Verify installation:"
echo "  $KUBECTL get pods -n longhorn-system"
echo "  $KUBECTL get storageclass"
echo ""
echo "Longhorn UI (if ingress enabled):"
echo "  $KUBECTL -n longhorn-system port-forward svc/longhorn-frontend 8080:80"
echo "  Access at: http://localhost:8080"
echo ""
