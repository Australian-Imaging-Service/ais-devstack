#!/bin/bash
# uninstall-squid.sh - Remove the Squid CVMFS cache deployment.
set -e

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

NS="${SQUID_NS:-mounts}"

if command -v microk8s &>/dev/null && microk8s status &>/dev/null; then
    KUBECTL="microk8s kubectl"
else
    KUBECTL="kubectl"
fi

echo -e "${BLUE}Removing Squid resources from namespace '$NS'${NC}"
echo ""
echo -e "${YELLOW}Reminder: revert CVMFS_HTTP_PROXY in jupyterhub/cvmfs_mount/values.yaml${NC}"
echo "back to \"DIRECT\" before uninstalling, otherwise CVMFS clients will hang"
echo "trying to reach the missing Squid service."
echo ""
read -p "Continue? (y/N): " ans
if [[ ! "$ans" =~ ^[Yy]$ ]]; then echo "Cancelled."; exit 0; fi

$KUBECTL -n "$NS" delete deploy/cvmfs-squid --ignore-not-found
$KUBECTL -n "$NS" delete svc/cvmfs-squid --ignore-not-found
$KUBECTL -n "$NS" delete cm/cvmfs-squid-config --ignore-not-found

read -p "Also delete the cache PVC (loses warmed cache)? (y/N): " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    $KUBECTL -n "$NS" delete pvc/cvmfs-squid-cache --ignore-not-found
fi

read -p "Remove the workload.cache/cvmfs-squid label from all nodes? (y/N): " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    for n in $($KUBECTL get nodes -o name); do
        $KUBECTL label "$n" workload.cache/cvmfs-squid- 2>/dev/null || true
    done
fi

echo ""
echo -e "${GREEN}Squid uninstall complete.${NC}"
