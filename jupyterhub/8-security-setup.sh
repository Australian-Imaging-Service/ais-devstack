#!/bin/bash
# 8-security-setup.sh - Setup Security Profiles Operator
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
echo "Setting up Security Profiles"
echo "Environment: ${ENV_NAME}"
echo "=========================================="

# Create security namespace
echo -e "${BLUE}[1/6] Installing cert-manager (required by security-profiles-operator)...${NC}"
if ! $KUBECTL get crd certificates.cert-manager.io &>/dev/null; then
    echo "Installing cert-manager..."
    $KUBECTL apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
    echo "Waiting for cert-manager to be ready..."
    sleep 10
    $KUBECTL wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=180s
else
    echo "cert-manager already installed"
fi

echo -e "${BLUE}[2/6] Creating security namespace...${NC}"
$KUBECTL apply -f "$SCRIPT_DIR/security/namespace.yaml"

# Install security-profiles-operator using Helm (neurodesk fork with abstract support)
echo -e "${BLUE}[3/6] Installing security-profiles-operator (neurodesk fork with Helm)...${NC}"
echo "Note: Using neurodesk fork which supports 'spec.abstract' API and AppArmor"

# Clone the neurodesk branch temporarily
TEMP_DIR=$(mktemp -d)
cd $TEMP_DIR
git clone --depth 1 --branch neurodesk https://github.com/Edan-Hamilton/security-profiles-operator.git
cd security-profiles-operator

# Install using Helm with AppArmor enabled
echo "Installing with Helm (enableAppArmor=true)..."
$HELM install security-profiles-operator ./deploy/helm \
  --namespace security \
  --set enableAppArmor=true \
  --set replicaCount=1

# Cleanup temp directory
cd -
rm -rf $TEMP_DIR

# Wait for operator to be ready
echo -e "${BLUE}[4/6] Waiting for operator...${NC}"
sleep 15
$KUBECTL wait --for=condition=ready pod \
  -l app=security-profiles-operator -n security --timeout=300s

# Patch spod daemonset for correct kubelet path
echo -e "${BLUE}[5/6] Patching spod for ${ENV_NAME} kubelet path...${NC}"
$KUBECTL patch daemonset spod -n security --type='json' -p="[
  {
    \"op\": \"replace\",
    \"path\": \"/spec/template/spec/initContainers/0/env/1/value\",
    \"value\": \"$KUBELET_PATH\"
  },
  {
    \"op\": \"replace\",
    \"path\": \"/spec/template/spec/containers/0/env/3/value\",
    \"value\": \"$KUBELET_PATH\"
  }
]"

# Wait for spod to be ready
echo "Waiting for spod to be ready..."
$KUBECTL wait --for=condition=ready pod -l name=spod -n security --timeout=300s

# Apply AppArmor profile
echo -e "${BLUE}[6/6] Creating AppArmor profile...${NC}"
$KUBECTL apply -f "$SCRIPT_DIR/security/apparmor-profile.yaml"

echo ""
echo -e "${GREEN}Security profiles setup completed${NC}"
echo ""
echo "Verify:"
echo "  $KUBECTL get pods -n security"
echo "  $KUBECTL get apparmorprofile -n security"
