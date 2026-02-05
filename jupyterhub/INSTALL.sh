#!/bin/bash
# Master installation script - runs complete installation sequence
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

# Setup kubectl access for k3s
setup_k3s_kubectl() {
    echo -e "${YELLOW}Setting up kubectl access for k3s...${NC}"

    # Create .kube directory
    mkdir -p ~/.kube

    # Copy k3s config to user's kubeconfig
    if [ -f /etc/rancher/k3s/k3s.yaml ]; then
        sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
        sudo chown $(id -u):$(id -g) ~/.kube/config
        chmod 600 ~/.kube/config
        echo -e "${GREEN}Kubectl config copied to ~/.kube/config${NC}"
    else
        echo -e "${RED}k3s config not found at /etc/rancher/k3s/k3s.yaml${NC}"
        return 1
    fi

    # Add KUBECONFIG to bashrc if not already present
    if ! grep -q "export KUBECONFIG=~/.kube/config" ~/.bashrc; then
        echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
        echo -e "${GREEN}Added KUBECONFIG to ~/.bashrc${NC}"
    fi

    # Export for current session
    export KUBECONFIG=~/.kube/config

    # Test kubectl access
    if kubectl get nodes &> /dev/null; then
        echo -e "${GREEN}kubectl is now working without sudo!${NC}"
        return 0
    else
        echo -e "${RED}kubectl still not working. Please check configuration.${NC}"
        return 1
    fi
}

ENV_TYPE=$(detect_environment)

if [ "$ENV_TYPE" = "microk8s" ]; then
    KUBECTL="microk8s kubectl"
    HELM="microk8s helm"
    ENV_NAME="MicroK8s"
elif [ "$ENV_TYPE" = "k3s" ] || [ "$ENV_TYPE" = "kubectl" ]; then
    # Check if kubectl works without sudo
    if ! kubectl get nodes &> /dev/null; then
        echo -e "${YELLOW}kubectl requires configuration for k3s...${NC}"
        if ! setup_k3s_kubectl; then
            echo -e "${RED}Failed to setup kubectl access${NC}"
            exit 1
        fi
    fi
    KUBECTL="kubectl"
    HELM="helm"
    ENV_NAME="k3s"
else
    echo -e "${RED}No Kubernetes environment detected.${NC}"
    echo "Please install k3s or MicroK8s first."
    exit 1
fi

echo -e "${BLUE}"
echo "=========================================="
echo "   JUPYTERHUB-XNAT INTEGRATION"
echo "   Master Installation Script"
echo "   Environment: ${ENV_NAME}"
echo "=========================================="
echo -e "${NC}"

# Function to wait for user confirmation
wait_for_user() {
    echo ""
    echo -e "${YELLOW}$1${NC}"
    read -p "Press ENTER to continue or Ctrl+C to abort..."
}

# Function to check if command succeeded
check_status() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}Done${NC}"
    else
        echo -e "${RED}Failed${NC}"
        echo "Check logs above for errors"
        exit 1
    fi
}

# Pre-flight checks
echo -e "${BLUE}[Pre-flight Checks]${NC}"
echo "Checking prerequisites..."

# Check kubectl/helm
if [ "$ENV_TYPE" = "microk8s" ]; then
    if ! microk8s status &> /dev/null; then
        echo -e "${RED}MicroK8s not running${NC}"
        exit 1
    fi
    echo -e "${GREEN}MicroK8s running${NC}"
else
    if ! $KUBECTL get nodes &> /dev/null; then
        echo -e "${RED}Cannot connect to Kubernetes cluster${NC}"
        exit 1
    fi
    echo -e "${GREEN}Kubernetes cluster accessible${NC}"
fi

# Check XNAT
if ! $KUBECTL get pods -n ais-xnat xnat-web-0 &>/dev/null; then
    echo -e "${RED}XNAT not found${NC}"
    echo "Please ensure XNAT is deployed in ais-xnat namespace"
    exit 1
fi
echo -e "${GREEN}XNAT found${NC}"

# Check NFS server
if ! $KUBECTL get pods -n storage -l app=nfs-server 2>/dev/null | grep -q Running; then
    echo -e "${YELLOW}Warning: NFS server may not be running${NC}"
    echo "Continuing anyway - ensure NFS is available"
else
    echo -e "${GREEN}NFS server found${NC}"
fi

echo ""
echo -e "${GREEN}Prerequisites check complete!${NC}"

wait_for_user "Ready to begin installation?"

# Step 1: Cleanup
echo ""
echo -e "${BLUE}=========================================="
echo "STEP 1: Cleanup Existing Installation"
echo "==========================================${NC}"
chmod +x "$SCRIPT_DIR/1-cleanup.sh"
"$SCRIPT_DIR/1-cleanup.sh"
check_status $?

wait_for_user "Cleanup complete. Ready to install Longhorn?"

# Step 2: Install Longhorn
echo ""
echo -e "${BLUE}=========================================="
echo "STEP 2: Installing Longhorn"
echo "==========================================${NC}"
chmod +x "$SCRIPT_DIR/2-install-longhorn.sh"
"$SCRIPT_DIR/2-install-longhorn.sh"
check_status $?

wait_for_user "Longhorn installed. Ready to install CVMFS?"

# Step 3: Install CVMFS
echo ""
echo -e "${BLUE}=========================================="
echo "STEP 3: Installing CVMFS CSI Driver"
echo "==========================================${NC}"
chmod +x "$SCRIPT_DIR/6-cvmfs-mounts.sh"
"$SCRIPT_DIR/6-cvmfs-mounts.sh"
check_status $?

wait_for_user "CVMFS installed. Ready to install Prometheus Monitoring?"

# Step 4: Install Prometheus Monitoring Stack
echo ""
echo -e "${BLUE}=========================================="
echo "STEP 4: Installing Prometheus Monitoring Stack"
echo "==========================================${NC}"
chmod +x "$SCRIPT_DIR/7-monitoring.sh"
"$SCRIPT_DIR/7-monitoring.sh"
check_status $?

wait_for_user "Prometheus Monitoring installed. Ready to install Security Profiles Operator?"

# Step 5: Install Security Profiles Operator
echo ""
echo -e "${BLUE}=========================================="
echo "STEP 5: Installing Security Profiles Operator"
echo "==========================================${NC}"
chmod +x "$SCRIPT_DIR/8-security-setup.sh"
"$SCRIPT_DIR/8-security-setup.sh"
check_status $?

wait_for_user "Security Profiles Operator installed. Ready to install JupyterHub?"

# Step 6: Install JupyterHub
echo ""
echo -e "${BLUE}=========================================="
echo "STEP 6: Installing JupyterHub"
echo "==========================================${NC}"
chmod +x "$SCRIPT_DIR/9-install-jupyterhub.sh"
"$SCRIPT_DIR/9-install-jupyterhub.sh"
check_status $?

wait_for_user "JupyterHub installed. Ready to verify?"

# Step 7: Verify Installation
echo ""
echo -e "${BLUE}=========================================="
echo "STEP 7: Verifying Installation"
echo "==========================================${NC}"

echo "Checking JupyterHub deployment..."
$KUBECTL get pods -n jupyter
echo ""
echo "Checking Security Profiles..."
$KUBECTL get apparmorprofile -n security 2>/dev/null || echo "No AppArmor profiles found"
echo ""
echo "Checking CVMFS mounts..."
$KUBECTL get pods -n mounts 2>/dev/null || echo "No CVMFS mounts namespace"
echo ""
echo "Checking Prometheus Monitoring..."
$KUBECTL get pods -n monitoring 2>/dev/null || echo "No monitoring namespace"
echo ""
echo "Checking Longhorn..."
$KUBECTL get pods -n longhorn-system 2>/dev/null || echo "No Longhorn namespace"

echo ""
echo -e "${GREEN}=========================================="
echo "  INSTALLATION COMPLETE!"
echo "==========================================${NC}"
echo ""
echo -e "${GREEN}All components installed${NC}"
echo ""
echo "Next Steps:"
echo "1. Configure XNAT Plugin (see XNAT-CONFIGURATION.md)"
echo "2. Enable JupyterHub for projects in XNAT"
echo "3. Test user workflow"
echo ""
echo "Access URLs:"
echo "  XNAT: http://xnat-test.ssdsorg.cloud.edu.au"
echo "  JupyterHub: http://xnat-test.ssdsorg.cloud.edu.au/jupyter"
echo "  Grafana: http://<node-ip>:31000 (admin/admin)"
echo ""
echo "Service Information:"
echo "  JupyterHub API: http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api"
echo "  Service Token: <jupyter-token>"
echo ""
echo "Documentation:"
echo "  README.md - Overview and architecture"
echo "  XNAT-CONFIGURATION.md - XNAT plugin setup"
echo "  TROUBLESHOOTING.md - Common issues and solutions"
echo ""
