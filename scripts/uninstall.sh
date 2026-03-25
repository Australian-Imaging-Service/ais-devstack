#!/bin/bash
# AIS-XNAT Unified Uninstall Script
# Automatically detects and handles both MicroK8s and k3s environments
# Note: not using set -e because cleanup commands may return non-zero and that's OK

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Detect environment
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

# Set kubectl and helm commands based on environment
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
    echo "Neither MicroK8s nor k3s appears to be installed/running."
    exit 1
fi

# Helper: remove orphaned webhooks that block kubectl operations
remove_orphaned_webhooks() {
    echo -e "${YELLOW}Removing orphaned admission webhooks...${NC}"
    # Longhorn webhooks
    $KUBECTL delete validatingwebhookconfiguration longhorn-webhook-validator 2>/dev/null || true
    $KUBECTL delete validatingwebhookconfiguration longhorn-admission-webhook 2>/dev/null || true
    $KUBECTL delete mutatingwebhookconfiguration longhorn-webhook-mutator 2>/dev/null || true
    $KUBECTL delete mutatingwebhookconfiguration longhorn-admission-webhook 2>/dev/null || true
    # SPO webhooks
    $KUBECTL delete mutatingwebhookconfiguration spo-mutating-webhook-configuration 2>/dev/null || true
    $KUBECTL delete validatingwebhookconfiguration spo-validating-webhook-configuration 2>/dev/null || true
    # cert-manager webhooks
    $KUBECTL delete mutatingwebhookconfiguration cert-manager-webhook 2>/dev/null || true
    $KUBECTL delete validatingwebhookconfiguration cert-manager-webhook 2>/dev/null || true
}

# Helper: strip finalizers from all PVCs in a namespace
strip_pvc_finalizers() {
    local ns=$1
    for pvc in $($KUBECTL get pvc -n "$ns" -o name 2>/dev/null || true); do
        $KUBECTL patch "$pvc" -n "$ns" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done
}

# Helper: strip finalizers from PVs by name
strip_pv_finalizers() {
    for pv in "$@"; do
        $KUBECTL patch pv "$pv" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done
}

# Helper: run a command with a timeout; if it hangs, fix webhooks/finalizers and retry
run_with_timeout() {
    local timeout_secs=$1
    local step_desc=$2
    shift 2
    local cmd="$@"

    # Run command in background
    eval "$cmd" &
    local pid=$!

    # Wait up to timeout_secs
    local elapsed=0
    while kill -0 $pid 2>/dev/null; do
        if [ $elapsed -ge $timeout_secs ]; then
            echo -e "${YELLOW}  ⚠ '$step_desc' stuck for ${timeout_secs}s — applying automatic fixes...${NC}"
            kill $pid 2>/dev/null || true
            wait $pid 2>/dev/null || true

            # Fix 1: Remove orphaned webhooks
            remove_orphaned_webhooks

            # Fix 2: Strip finalizers from PVCs in ais-xnat
            strip_pvc_finalizers "ais-xnat"

            # Fix 3: Strip finalizers from known XNAT PVs
            strip_pv_finalizers xnat-nfs xnat-build xnat-gpfs

            # Fix 4: Strip namespace finalizers
            if $KUBECTL get namespace ais-xnat &>/dev/null; then
                $KUBECTL get namespace ais-xnat -o json 2>/dev/null | \
                    jq '.spec.finalizers = []' | \
                    $KUBECTL replace --raw "/api/v1/namespaces/ais-xnat/finalize" -f - 2>/dev/null || true
            fi

            echo -e "${YELLOW}  Retrying '$step_desc'...${NC}"
            eval "$cmd" &
            local retry_pid=$!
            local retry_elapsed=0
            while kill -0 $retry_pid 2>/dev/null; do
                if [ $retry_elapsed -ge 15 ]; then
                    echo -e "${YELLOW}  ⚠ Retry timed out, continuing...${NC}"
                    kill $retry_pid 2>/dev/null || true
                    wait $retry_pid 2>/dev/null || true
                    return 0
                fi
                sleep 1
                retry_elapsed=$((retry_elapsed + 1))
            done
            wait $retry_pid 2>/dev/null || true
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait $pid 2>/dev/null || true
}

echo -e "${BLUE}"
echo "=========================================="
echo "   AIS-XNAT Uninstallation"
echo "   Detected environment: ${ENV_NAME}"
echo "=========================================="
echo -e "${NC}"

echo -e "${YELLOW}This will remove:${NC}"
echo "  - XNAT Helm release"
echo "  - ais-xnat namespace and all resources"
echo "  - NFS server (optional)"
echo "  - NFS CSI driver (optional)"
echo "  - NGINX Ingress Controller (optional)"
if [ "$ENV_TYPE" = "microk8s" ]; then
    echo "  - MicroK8s installation (optional)"
elif [ "$ENV_TYPE" = "k3s" ]; then
    echo "  - k3s installation (optional)"
    echo "  - Helm (optional)"
fi
echo ""
read -p "Continue? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Step 0: Pre-emptively remove orphaned webhooks that can block kubectl operations
echo -e "${BLUE}[0/6] Removing orphaned admission webhooks (prevents hangs)...${NC}"
remove_orphaned_webhooks

# Step 1: Uninstall XNAT Helm release
echo -e "${BLUE}[1/6] Uninstalling XNAT...${NC}"
run_with_timeout 30 "Helm uninstall" "$HELM uninstall xnat-web -n ais-xnat 2>/dev/null || echo 'XNAT release not found'"

# Step 2: Delete XNAT namespace resources
echo -e "${BLUE}[2/6] Cleaning up ais-xnat namespace...${NC}"
run_with_timeout 30 "Delete all resources" "$KUBECTL delete all --all -n ais-xnat --force --grace-period=0 2>/dev/null || true"
run_with_timeout 30 "Delete PVCs" "$KUBECTL delete pvc --all -n ais-xnat --force --grace-period=0 2>/dev/null || true"
$KUBECTL delete configmap --all -n ais-xnat 2>/dev/null || true
$KUBECTL delete secret --all -n ais-xnat 2>/dev/null || true

# Check for stuck PVCs and strip finalizers
STUCK_PVCS=$($KUBECTL get pvc -n ais-xnat -o jsonpath='{.items[?(@.metadata.deletionTimestamp)].metadata.name}' 2>/dev/null || true)
if [ -n "$STUCK_PVCS" ]; then
    echo -e "${YELLOW}  Found stuck PVCs, stripping finalizers...${NC}"
    strip_pvc_finalizers "ais-xnat"
    sleep 3
fi

# Step 3: Delete namespace
echo -e "${BLUE}[3/6] Deleting ais-xnat namespace...${NC}"
run_with_timeout 30 "Delete namespace" "$KUBECTL delete namespace ais-xnat 2>/dev/null || echo 'Namespace already deleted'"

# If namespace is still stuck, force-remove finalizers
if $KUBECTL get namespace ais-xnat &>/dev/null; then
    echo -e "${YELLOW}  Namespace stuck in Terminating, forcing removal...${NC}"
    $KUBECTL get namespace ais-xnat -o json 2>/dev/null | \
        jq '.spec.finalizers = []' | \
        $KUBECTL replace --raw "/api/v1/namespaces/ais-xnat/finalize" -f - 2>/dev/null || true
fi

# Step 4: Delete XNAT PVs
echo -e "${BLUE}[4/6] Cleaning up PersistentVolumes...${NC}"
# Strip finalizers first to prevent hanging
strip_pv_finalizers xnat-nfs xnat-build xnat-gpfs
$KUBECTL delete pv xnat-nfs xnat-build xnat-gpfs 2>/dev/null || echo "PVs already deleted"

# Step 5: Optional - Remove NFS server
echo ""
read -p "Also remove NFS server? (y/N): " remove_nfs
if [[ "$remove_nfs" =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}[5/6] Removing NFS server...${NC}"
    $HELM uninstall nfs-server -n storage 2>/dev/null || echo "NFS server not found"
    $KUBECTL delete namespace storage 2>/dev/null || true

    # Optional - Remove NFS CSI driver
    read -p "Also remove NFS CSI driver? (y/N): " remove_csi
    if [[ "$remove_csi" =~ ^[Yy]$ ]]; then
        $HELM uninstall csi-driver-nfs -n kube-system 2>/dev/null || echo "CSI driver not found"
    fi

    # Optional - Remove NGINX Ingress (k3s only)
    if [ "$ENV_TYPE" = "k3s" ] || [ "$ENV_TYPE" = "kubectl" ]; then
        read -p "Also remove NGINX Ingress Controller? (y/N): " remove_nginx
        if [[ "$remove_nginx" =~ ^[Yy]$ ]]; then
            $HELM uninstall ingress-nginx -n ingress-nginx 2>/dev/null || echo "NGINX Ingress not found"
            $KUBECTL delete namespace ingress-nginx 2>/dev/null || true
        fi
    fi
fi

# Step 6: Environment-specific cleanup
if [ "$ENV_TYPE" = "microk8s" ]; then
    echo ""
    read -p "Also remove MicroK8s completely? (y/N): " remove_microk8s
    if [[ "$remove_microk8s" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}[6/6] Removing MicroK8s...${NC}"

        # Stop MicroK8s
        sudo microk8s stop 2>/dev/null || true

        # Remove MicroK8s
        sudo snap remove microk8s --purge 2>/dev/null || true

        # Clean up shell aliases
        echo "Cleaning up shell aliases..."
        sed -i '/alias kubectl="microk8s kubectl"/d' ~/.bashrc 2>/dev/null || true
        sed -i '/alias k="microk8s kubectl"/d' ~/.bashrc 2>/dev/null || true
        sed -i '/alias helm="microk8s helm"/d' ~/.bashrc 2>/dev/null || true

        echo -e "${YELLOW}MicroK8s removed. Run 'source ~/.bashrc' to refresh your shell.${NC}"

        read -p "Also remove MicroK8s data directory? (y/N): " remove_data
        if [[ "$remove_data" =~ ^[Yy]$ ]]; then
            sudo rm -rf /var/snap/microk8s 2>/dev/null || true
            echo "MicroK8s data directory removed."
        fi
    fi
elif [ "$ENV_TYPE" = "k3s" ]; then
    echo ""
    read -p "Also remove k3s completely? (y/N): " remove_k3s
    if [[ "$remove_k3s" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}[6/6] Removing k3s...${NC}"

        if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
            /usr/local/bin/k3s-uninstall.sh
        else
            echo -e "${YELLOW}k3s uninstall script not found at /usr/local/bin/k3s-uninstall.sh${NC}"
            echo "You may need to manually remove k3s."
        fi

        # Clean up kubeconfig
        rm -f ~/.kube/config 2>/dev/null || true
    fi

    # Option to remove Helm (installed separately in k3s)
    echo ""
    read -p "Also remove Helm? (y/N): " remove_helm
    if [[ "$remove_helm" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Removing Helm...${NC}"
        sudo rm -f /usr/local/bin/helm 2>/dev/null || true
        rm -rf ~/.cache/helm ~/.config/helm ~/.local/share/helm 2>/dev/null || true
        echo -e "${GREEN}Helm removed${NC}"
    fi
fi

echo ""
echo -e "${GREEN}=========================================="
echo "   Uninstallation Complete"
echo "==========================================${NC}"
echo ""
echo "Verify cleanup:"
if [ "$ENV_TYPE" != "none" ] && command -v $KUBECTL &> /dev/null; then
    echo "  $KUBECTL get ns | grep -E 'ais-xnat|storage'"
    echo "  $KUBECTL get pv | grep xnat"
    echo "  $HELM list -A | grep -E 'xnat|nfs'"
fi
echo ""
