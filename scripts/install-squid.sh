#!/bin/bash
# install-squid.sh - Deploy Squid HTTP proxy as a shared CVMFS cache.
# Idempotent. Detects k3s vs MicroK8s. Renders manifests with cluster-specific values.
set -e

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
SQUID_DIR="$BASE_DIR/squid"
NS="${SQUID_NS:-mounts}"

# --- Detect environment ---
if command -v microk8s &>/dev/null && microk8s status &>/dev/null; then
    KUBECTL="microk8s kubectl"; ENV_NAME="MicroK8s"
    DEFAULT_SC="microk8s-hostpath"
elif command -v k3s &>/dev/null || [ -f /etc/rancher/k3s/k3s.yaml ]; then
    KUBECTL="kubectl"; ENV_NAME="k3s"
    DEFAULT_SC="local-path"
elif command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null; then
    KUBECTL="kubectl"; ENV_NAME="generic"
    DEFAULT_SC="$($KUBECTL get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' | awk '{print $1}')"
else
    echo -e "${RED}No Kubernetes environment detected.${NC}"; exit 1
fi

SC="${SQUID_SC:-$DEFAULT_SC}"

echo -e "${BLUE}==========================================${NC}"
echo "  Squid CVMFS Cache Installer"
echo "  Environment: ${ENV_NAME}"
echo "  Namespace:   ${NS}"
echo "  StorageClass: ${SC}"
echo -e "${BLUE}==========================================${NC}"

# --- Discover CIDRs ---
discover_cidrs() {
    POD_CIDR="$($KUBECTL get nodes -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null || true)"
    if [ -z "$POD_CIDR" ]; then
        # k3s default
        POD_CIDR="10.42.0.0/16"
    fi
    # Try to read service CIDR from kube-apiserver args; fallback to k3s/microk8s defaults
    SVC_CIDR="$($KUBECTL -n kube-system get pod -l component=kube-apiserver -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null \
        | tr ',' '\n' | grep -oE 'service-cluster-ip-range=[^"]+' | cut -d= -f2 || true)"
    if [ -z "$SVC_CIDR" ]; then
        SVC_CIDR="10.43.0.0/16"
    fi
}
discover_cidrs

POD_CIDR="${SQUID_POD_CIDR:-$POD_CIDR}"
SVC_CIDR="${SQUID_SVC_CIDR:-$SVC_CIDR}"
echo "  Pod CIDR:     ${POD_CIDR}"
echo "  Svc CIDR:     ${SVC_CIDR}"

# --- Pick a node ---
NODE_COUNT=$($KUBECTL get nodes --no-headers | wc -l)
if [ -n "${SQUID_NODE:-}" ]; then
    NODE="$SQUID_NODE"
elif [ "$NODE_COUNT" -eq 1 ]; then
    NODE=$($KUBECTL get nodes -o jsonpath='{.items[0].metadata.name}')
else
    echo -e "${YELLOW}Multiple nodes detected. Pin Squid via SQUID_NODE=<name> or accept the first node.${NC}"
    NODE=$($KUBECTL get nodes -o jsonpath='{.items[0].metadata.name}')
fi
echo "  Squid node:   ${NODE}"
echo ""

# --- Pre-flight checks ---
echo -e "${BLUE}[Pre-flight]${NC}"
if ! $KUBECTL get sc "$SC" &>/dev/null; then
    echo -e "${RED}StorageClass '$SC' not found. Override with SQUID_SC=<name>.${NC}"; exit 1
fi
echo -e "${GREEN}StorageClass '$SC' present${NC}"

read -p "Proceed with installation? (Y/n): " ans
if [[ "$ans" =~ ^[Nn]$ ]]; then echo "Cancelled."; exit 0; fi
echo ""

# --- Apply ---
echo -e "${BLUE}[1/4] Ensuring namespace '$NS' exists${NC}"
$KUBECTL create namespace "$NS" --dry-run=client -o yaml | $KUBECTL apply -f -

echo -e "${BLUE}[2/4] Labeling node '$NODE'${NC}"
$KUBECTL label node "$NODE" workload.cache/cvmfs-squid=true --overwrite

echo -e "${BLUE}[3/4] Rendering manifests${NC}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
for f in squid-configmap.yaml squid-pvc.yaml squid-deployment.yaml squid-service.yaml; do
    sed -e "s|__NS__|$NS|g" \
        -e "s|__SC__|$SC|g" \
        -e "s|__POD_CIDR__|$POD_CIDR|g" \
        -e "s|__SVC_CIDR__|$SVC_CIDR|g" \
        "$SQUID_DIR/$f" > "$TMP/$f"
done

echo -e "${BLUE}[4/4] Applying manifests${NC}"
$KUBECTL apply -f "$TMP/squid-configmap.yaml"
$KUBECTL apply -f "$TMP/squid-pvc.yaml"
$KUBECTL apply -f "$TMP/squid-service.yaml"
$KUBECTL apply -f "$TMP/squid-deployment.yaml"

echo ""
echo -e "${BLUE}Waiting for pod to become ready...${NC}"
$KUBECTL -n "$NS" rollout status deploy/cvmfs-squid --timeout=180s || true

echo ""
echo -e "${GREEN}=========================================="
echo "  Squid installed"
echo "==========================================${NC}"
echo ""
echo "Verify:"
echo "  $KUBECTL -n $NS get pod -l app=cvmfs-squid -o wide"
echo "  $KUBECTL -n $NS logs deploy/cvmfs-squid -c log-tail -f --tail=50"
echo ""
echo -e "${YELLOW}Next step — point CVMFS clients at Squid${NC}"
echo "Edit jupyterhub/cvmfs_mount/values.yaml line ~68:"
echo ""
echo '  CVMFS_HTTP_PROXY="DIRECT"'
echo "becomes"
echo "  CVMFS_HTTP_PROXY=\"http://cvmfs-squid.${NS}.svc.cluster.local:3128|DIRECT\""
echo ""
echo "Then re-run jupyterhub/6-cvmfs-mounts.sh (or helm upgrade cvmfs-csi)."
echo ""
echo "Verify TAB separator in storeid.conf (must be a real tab, not spaces):"
echo "  $KUBECTL -n $NS get cm cvmfs-squid-config -o jsonpath='{.data.storeid\\.conf}' | cat -A"
