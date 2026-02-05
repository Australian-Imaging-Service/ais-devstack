#!/bin/bash
# Complete cleanup of JupyterHub, Longhorn, Security Profiles, and CVMFS installation
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
elif [ "$ENV_TYPE" = "k3s" ] || [ "$ENV_TYPE" = "kubectl" ]; then
    KUBECTL="kubectl"
    HELM="helm"
    ENV_NAME="k3s"
else
    echo -e "${RED}No Kubernetes environment detected.${NC}"
    exit 1
fi

echo "=========================================="
echo "CLEANUP: Removing JupyterHub, Monitoring, Longhorn, Security, and CVMFS"
echo "Environment: ${ENV_NAME}"
echo "=========================================="

# 1. Delete JupyterHub Helm release
echo -e "${BLUE}[1/10] Uninstalling JupyterHub Helm release...${NC}"

# Clean up any stuck Helm releases first
if $KUBECTL get namespace jupyter &>/dev/null; then
    $KUBECTL delete secret -n jupyter -l owner=helm,name=jupyterhub 2>/dev/null || true
fi

$HELM uninstall jupyterhub -n jupyter 2>/dev/null || echo "JupyterHub not found or already removed"

# 2. Delete all jupyter namespace resources
echo -e "${BLUE}[2/10] Deleting all resources in jupyter namespace...${NC}"
$KUBECTL delete all --all -n jupyter --force --grace-period=0 2>/dev/null || true
$KUBECTL delete pvc --all -n jupyter --force --grace-period=0 2>/dev/null || true
$KUBECTL delete configmap --all -n jupyter 2>/dev/null || true
$KUBECTL delete secret --all -n jupyter 2>/dev/null || true
$KUBECTL delete daemonset --all -n jupyter --force --grace-period=0 2>/dev/null || true

# Wait for pods to terminate
echo "Waiting for jupyter pods to terminate..."
$KUBECTL wait --for=delete pod --all -n jupyter --timeout=30s 2>/dev/null || true

# Remove finalizers from any stuck pods
for pod in $($KUBECTL get pods -n jupyter -o name 2>/dev/null || true); do
    $KUBECTL patch $pod -n jupyter -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    $KUBECTL delete $pod -n jupyter --force --grace-period=0 2>/dev/null || true
done

# 3. Delete jupyter namespace
echo -e "${BLUE}[3/10] Deleting jupyter namespace...${NC}"
if $KUBECTL get namespace jupyter &>/dev/null; then
    $KUBECTL delete namespace jupyter --timeout=30s 2>/dev/null || \
        $KUBECTL delete namespace jupyter --force --grace-period=0 2>/dev/null || true
else
    echo "Namespace already deleted"
fi

# 4. Remove Security Profiles Operator
echo -e "${BLUE}[4/10] Uninstalling Security Profiles Operator...${NC}"

# Clean up any stuck Helm releases first
if $KUBECTL get namespace security &>/dev/null; then
    $KUBECTL delete secret -n security -l owner=helm,name=security-profiles-operator 2>/dev/null || true
fi

$HELM uninstall security-profiles-operator -n security 2>/dev/null || echo "SPO not found or already removed"

# Delete security namespace resources
echo "Cleaning up security namespace resources..."
$KUBECTL delete all --all -n security --force --grace-period=0 2>/dev/null || true

# Wait for pods to terminate
$KUBECTL wait --for=delete pod --all -n security --timeout=30s 2>/dev/null || true

# Remove finalizers from any stuck pods
for pod in $($KUBECTL get pods -n security -o name 2>/dev/null || true); do
    $KUBECTL patch $pod -n security -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    $KUBECTL delete $pod -n security --force --grace-period=0 2>/dev/null || true
done

# 5. Delete security namespace
echo -e "${BLUE}[5/10] Deleting security namespace...${NC}"
if $KUBECTL get namespace security &>/dev/null; then
    $KUBECTL delete namespace security --timeout=30s 2>/dev/null || \
        $KUBECTL delete namespace security --force --grace-period=0 2>/dev/null || true
else
    echo "Security namespace already deleted"
fi

# Clean up cluster-scoped SPO resources
echo "Cleaning up cluster-scoped security resources..."

# Delete all SPO CRDs (this will cascade delete all CR instances)
$KUBECTL get crd 2>/dev/null | grep 'security-profiles-operator.x-k8s.io' | awk '{print $1}' | xargs -r $KUBECTL delete crd 2>/dev/null || true

# Delete ClusterRoles and ClusterRoleBindings
$KUBECTL get clusterrole 2>/dev/null | grep -E "(spo-|security-profiles)" | awk '{print $1}' | xargs -r $KUBECTL delete clusterrole 2>/dev/null || true
$KUBECTL get clusterrolebinding 2>/dev/null | grep -E "(spo-|security-profiles)" | awk '{print $1}' | xargs -r $KUBECTL delete clusterrolebinding 2>/dev/null || true

# Delete webhooks
$KUBECTL delete mutatingwebhookconfiguration spo-mutating-webhook-configuration 2>/dev/null || true
$KUBECTL delete validatingwebhookconfiguration spo-validating-webhook-configuration 2>/dev/null || true

# Delete any ServiceMonitors
$KUBECTL delete servicemonitor -n security --all 2>/dev/null || true

# Clean up cert-manager (installed for security-profiles-operator)
echo "Cleaning up cert-manager..."
$KUBECTL delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml 2>/dev/null || echo "cert-manager not found or already removed"

# Wait for cert-manager namespace to be deleted
$KUBECTL wait --for=delete namespace cert-manager --timeout=60s 2>/dev/null || true

# 6. Remove Prometheus Monitoring Stack
echo -e "${BLUE}[6/10] Uninstalling Prometheus Monitoring Stack...${NC}"

# Clean up any stuck Helm releases first
if $KUBECTL get namespace monitoring &>/dev/null; then
    $KUBECTL delete secret -n monitoring -l owner=helm,name=prometheus 2>/dev/null || true
fi

$HELM uninstall prometheus -n monitoring 2>/dev/null || echo "Prometheus not found or already removed"

# Delete monitoring namespace resources
echo "Cleaning up monitoring namespace resources..."
$KUBECTL delete all --all -n monitoring --force --grace-period=0 2>/dev/null || true
$KUBECTL delete pvc --all -n monitoring --force --grace-period=0 2>/dev/null || true

# Explicitly delete deployments, daemonsets, and statefulsets
$KUBECTL delete deployment --all -n monitoring --force --grace-period=0 2>/dev/null || true
$KUBECTL delete daemonset --all -n monitoring --force --grace-period=0 2>/dev/null || true
$KUBECTL delete statefulset --all -n monitoring --force --grace-period=0 2>/dev/null || true

# Wait for pods to terminate
$KUBECTL wait --for=delete pod --all -n monitoring --timeout=30s 2>/dev/null || true

# Remove finalizers from any stuck pods
for pod in $($KUBECTL get pods -n monitoring -o name 2>/dev/null || true); do
    $KUBECTL patch $pod -n monitoring -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    $KUBECTL delete $pod -n monitoring --force --grace-period=0 2>/dev/null || true
done

# Delete monitoring namespace
if $KUBECTL get namespace monitoring &>/dev/null; then
    $KUBECTL delete namespace monitoring --timeout=30s 2>/dev/null || \
        $KUBECTL delete namespace monitoring --force --grace-period=0 2>/dev/null || true
else
    echo "Monitoring namespace already deleted"
fi

# Clean up Prometheus webhooks and CRDs
$KUBECTL delete validatingwebhookconfiguration prometheus-monitor-admission 2>/dev/null || true
$KUBECTL delete mutatingwebhookconfiguration prometheus-monitor-admission 2>/dev/null || true
$KUBECTL get crd 2>/dev/null | grep 'monitoring.coreos.com' | awk '{print $1}' | xargs -r $KUBECTL delete crd 2>/dev/null || true

# 7. Remove Longhorn
echo -e "${BLUE}[6/9] Uninstalling Longhorn...${NC}"

# Clean up any stuck Helm releases first
if $KUBECTL get namespace longhorn-system &>/dev/null; then
    # Delete Helm release secrets to clear stuck state
    $KUBECTL delete secret -n longhorn-system -l owner=helm,name=longhorn 2>/dev/null || true
fi

$HELM uninstall longhorn -n longhorn-system 2>/dev/null || echo "Longhorn not found or already removed"

# Delete Longhorn webhooks first (critical - these block namespace deletion)
echo "Removing Longhorn webhooks..."
$KUBECTL delete validatingwebhookconfiguration longhorn-admission-webhook 2>/dev/null || true
$KUBECTL delete mutatingwebhookconfiguration longhorn-admission-webhook 2>/dev/null || true

# Remove finalizers from Longhorn resources to prevent namespace from hanging
if $KUBECTL get namespace longhorn-system &>/dev/null; then
    echo "Removing Longhorn resource finalizers..."

    # Delete all deployments and daemonsets first
    echo "Deleting Longhorn deployments and daemonsets..."
    $KUBECTL delete deployment --all -n longhorn-system --force --grace-period=0 2>/dev/null || true
    $KUBECTL delete daemonset --all -n longhorn-system --force --grace-period=0 2>/dev/null || true

    # Remove finalizers from volumes
    for volume in $($KUBECTL get volumes.longhorn.io -n longhorn-system -o name 2>/dev/null || true); do
        $KUBECTL patch $volume -n longhorn-system -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done
    # Remove finalizers from replicas
    for replica in $($KUBECTL get replicas.longhorn.io -n longhorn-system -o name 2>/dev/null || true); do
        $KUBECTL patch $replica -n longhorn-system -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done
    # Remove finalizers from engines
    for engine in $($KUBECTL get engines.longhorn.io -n longhorn-system -o name 2>/dev/null || true); do
        $KUBECTL patch $engine -n longhorn-system -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done

    # Remove finalizers from pods and force delete them
    echo "Removing pod finalizers and force-deleting pods..."
    for pod in $($KUBECTL get pods -n longhorn-system -o name 2>/dev/null || true); do
        $KUBECTL patch $pod -n longhorn-system -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        $KUBECTL delete $pod -n longhorn-system --force --grace-period=0 2>/dev/null || true
    done

    # Wait for pods to be deleted
    sleep 5
fi

# CRITICAL: Delete Longhorn CRDs BEFORE deleting namespace
# This ensures custom resources are properly cleaned up
echo "Deleting Longhorn CRDs (this will cascade delete all CR instances)..."
LONGHORN_CRDS=$($KUBECTL get crd -o name 2>/dev/null | grep 'longhorn.io' || true)
if [ -n "$LONGHORN_CRDS" ]; then
    echo "$LONGHORN_CRDS" | xargs -r $KUBECTL delete --wait=false 2>&1 | grep -v "NotFound" || true

    # Wait and retry with finalizer removal if needed
    for attempt in 1 2 3; do
        REMAINING=$($KUBECTL get crd 2>/dev/null | grep 'longhorn.io' | awk '{print $1}')
        if [ -z "$REMAINING" ]; then
            echo "  ✓ All Longhorn CRDs deleted"
            break
        fi
        echo "  Attempt $attempt: Removing CRD finalizers..."
        echo "$REMAINING" | xargs -r -I{} $KUBECTL patch crd {} --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        echo "$REMAINING" | xargs -r $KUBECTL delete crd --wait=false 2>/dev/null || true
        sleep 3
    done
else
    echo "  ✓ No Longhorn CRDs found"
fi

# Clean up ALL remaining Longhorn resources before deleting namespace
if $KUBECTL get namespace longhorn-system &>/dev/null; then
    echo "Cleaning up all remaining Longhorn resources..."

    # Delete all standard Kubernetes resources
    $KUBECTL delete svc --all -n longhorn-system --force --grace-period=0 2>/dev/null || true
    $KUBECTL delete deployment --all -n longhorn-system --force --grace-period=0 2>/dev/null || true
    $KUBECTL delete daemonset --all -n longhorn-system --force --grace-period=0 2>/dev/null || true
    $KUBECTL delete statefulset --all -n longhorn-system --force --grace-period=0 2>/dev/null || true
    $KUBECTL delete replicaset --all -n longhorn-system --force --grace-period=0 2>/dev/null || true

    # Force delete any remaining pods
    for pod in $($KUBECTL get pods -n longhorn-system -o name 2>/dev/null || true); do
        $KUBECTL patch $pod -n longhorn-system -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        $KUBECTL delete $pod -n longhorn-system --force --grace-period=0 2>/dev/null || true
    done

    # Wait for cascading deletions to complete
    echo "Waiting for resource cleanup to complete..."
    sleep 10
fi

# Now delete the namespace (should be quick since CRDs and resources are gone)
if $KUBECTL get namespace longhorn-system &>/dev/null; then
    echo "Deleting longhorn-system namespace..."
    if ! $KUBECTL delete namespace longhorn-system --timeout=30s 2>/dev/null; then
        # If deletion hangs, remove namespace finalizers directly
        echo "Removing namespace finalizers..."
        $KUBECTL get namespace longhorn-system -o json 2>/dev/null | \
            jq '.spec.finalizers = []' | \
            $KUBECTL replace --raw "/api/v1/namespaces/longhorn-system/finalize" -f - 2>/dev/null || true
    fi
else
    echo "Longhorn namespace already deleted"
fi

# 7. Clean up any orphaned PVs
echo -e "${BLUE}[8/10] Cleaning up orphaned PersistentVolumes...${NC}"

# First, clear claimRef from any Released PVs to prevent binding issues
echo "  Clearing claimRef from Released PVs..."
for pv in $($KUBECTL get pv -o json | jq -r '.items[] | select(.status.phase == "Released") | .metadata.name' 2>/dev/null || true); do
  echo "    Resetting PV: $pv"
  $KUBECTL patch pv "$pv" -p '{"spec":{"claimRef": null}}' 2>/dev/null || true
done

# Also specifically handle jupyter-xnat-gpfs-shared if it exists
if $KUBECTL get pv jupyter-xnat-gpfs-shared &>/dev/null; then
  echo "  Clearing claimRef from jupyter-xnat-gpfs-shared..."
  $KUBECTL patch pv jupyter-xnat-gpfs-shared -p '{"spec":{"claimRef": null}}' 2>/dev/null || true
fi

# Then delete orphaned PVs with finalizer handling
echo "  Deleting orphaned PVs..."
for pv in $($KUBECTL get pv -o name 2>/dev/null | grep -E "jupyter|longhorn" || true); do
    pv_name=$(echo $pv | cut -d'/' -f2)
    echo "    Deleting PV: $pv_name"
    # Remove finalizers first
    $KUBECTL patch pv "$pv_name" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    # Delete with timeout
    $KUBECTL delete pv "$pv_name" --timeout=10s 2>/dev/null || true
done

# 8. Complete CVMFS cleanup
echo -e "${BLUE}[9/10] Uninstalling CVMFS completely...${NC}"

# Delete CVMFS PVC first (prevents volume leak)
echo "  Deleting CVMFS PVC..."
$KUBECTL delete pvc cvmfs -n jupyter --ignore-not-found=true 2>/dev/null || true

# Wait for PVC deletion
sleep 5

# Delete CVMFS PVs
echo "  Cleaning up CVMFS PVs..."
$KUBECTL get pv 2>/dev/null | grep cvmfs | awk '{print $1}' | xargs -r $KUBECTL delete pv --ignore-not-found=true 2>/dev/null || true

# Clean up any stuck Helm releases first
if $KUBECTL get namespace mounts &>/dev/null; then
    $KUBECTL delete secret -n mounts -l owner=helm,name=cvmfs-csi 2>/dev/null || true
    $KUBECTL delete secret -n mounts -l owner=helm,name=smarter-device-manager 2>/dev/null || true
fi

# Uninstall CVMFS CSI driver from both possible namespaces
echo "  Uninstalling CVMFS CSI driver..."
$HELM uninstall cvmfs-csi -n mounts 2>/dev/null || true

# Uninstall smarter-device-manager
echo "  Uninstalling smarter-device-manager..."
$HELM uninstall smarter-device-manager -n mounts 2>/dev/null || true

# Remove node labels
echo "  Removing node labels..."
$KUBECTL get nodes -o name 2>/dev/null | while read node; do
  $KUBECTL label $node smarter-device-manager- --overwrite 2>/dev/null || true
done

# Delete CVMFS StorageClass
echo "  Deleting CVMFS StorageClass..."
$KUBECTL delete storageclass cvmfs --ignore-not-found=true 2>/dev/null || true

# Delete CVMFS namespace with finalizer handling
if $KUBECTL get namespace mounts &>/dev/null; then
    echo "  Deleting mounts namespace..."
    # First delete all resources in the namespace
    $KUBECTL delete all --all -n mounts --timeout=30s 2>/dev/null || true

    # Force delete deployments and daemonsets first
    $KUBECTL delete deployment --all -n mounts --force --grace-period=0 2>/dev/null || true
    $KUBECTL delete daemonset --all -n mounts --force --grace-period=0 2>/dev/null || true

    # Remove finalizers from any stuck pods and force delete them
    for pod in $($KUBECTL get pods -n mounts -o name 2>/dev/null || true); do
        $KUBECTL patch $pod -n mounts -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        $KUBECTL delete $pod -n mounts --force --grace-period=0 2>/dev/null || true
    done

    # Wait a moment for pods to be deleted
    sleep 3

    # Now delete the namespace
    $KUBECTL delete namespace mounts --timeout=30s 2>/dev/null || \
        $KUBECTL delete namespace mounts --force --grace-period=0 2>/dev/null || true
else
    echo "  Mounts namespace already deleted"
fi

# Clean up CVMFS DaemonSet if exists
$KUBECTL delete daemonset cvmfs-nodeplugin -n kube-system 2>/dev/null || true

# 9. Clean up CVMFS on nodes
echo -e "${BLUE}[10/10] Cleaning up CVMFS mounts...${NC}"
# Unmount CVMFS repositories
if mount | grep -q /cvmfs; then
    echo "  Unmounting CVMFS repositories..."
    sudo umount -l /cvmfs/* 2>/dev/null || true
    sudo umount -l /cvmfs 2>/dev/null || true
fi

# Clean up CVMFS cache and config
if [ -d /var/lib/cvmfs ]; then
    echo "  Removing CVMFS cache..."
    sudo rm -rf /var/lib/cvmfs/* 2>/dev/null || true
fi

# Remove AppArmor profiles loaded by SPO
if command -v aa-status >/dev/null 2>&1; then
    if sudo aa-status | grep -q notebook; then
        echo "  Removing AppArmor notebook profile..."
        echo "profile notebook {}" | sudo apparmor_parser -R 2>/dev/null || true
    fi
fi

echo ""
echo -e "${GREEN}=========================================="
echo "CLEANUP COMPLETE"
echo "==========================================${NC}"
echo ""
echo "Verify cleanup:"
echo "  $KUBECTL get all -n jupyter"
echo "  $KUBECTL get all -n security"
echo "  $KUBECTL get all -n mounts"
echo "  $KUBECTL get pvc -n jupyter"
echo "  $KUBECTL get ns | grep -E 'jupyter|security|mounts|longhorn'"
echo "  $HELM list -A"
echo "  mount | grep cvmfs"
echo "  sudo aa-status | grep notebook"
echo ""


# -------- LONGHORN ULTRA-CLEANUP (timeout-safe, nuclear option) --------
# Usage: Uncomment the below section (from START to END) to run aggressive Longhorn cleanup
# Note: This is a more aggressive cleanup for Longhorn installations
# that may be stuck due to finalizers, webhooks, or other issues.
# This section uses timeout commands to prevent hangs.
# -------------------- START --------------------

# echo ""
# echo "=========================================="
# echo "LONGHORN ULTRA-CLEANUP: Removing all Longhorn resources"
# echo "Environment: ${ENV_NAME}"
# echo "=========================================="

# # Timeout wrapper function
# k() {
#   timeout 8s $KUBECTL --request-timeout=6s "$@" 2>/dev/null
# }

# echo ">>> Using KUBECTL='$KUBECTL'"
# $KUBECTL version --client >/dev/null 2>&1 || { echo "ERR: '$KUBECTL' not found/working."; exit 1; }

# echo ">>> [0] Unstick namespace (remove finalizers if present)"
# k get ns longhorn-system >/dev/null && \
#   $KUBECTL patch namespace longhorn-system --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true

# echo ">>> [1] Remove admission webhooks (prevents CR deletes from hanging)"
# k get mutatingwebhookconfiguration -o name | grep -i longhorn | xargs -r $KUBECTL delete >/dev/null 2>&1 || true
# k get validatingwebhookconfiguration -o name | grep -i longhorn | xargs -r $KUBECTL delete >/dev/null 2>&1 || true

# echo ">>> [2] Remove StorageClasses & CSIDriver"
# $KUBECTL delete sc longhorn longhorn-static --ignore-not-found >/dev/null 2>&1 || true
# $KUBECTL delete csidriver driver.longhorn.io --ignore-not-found >/dev/null 2>&1 || true

# echo ">>> [3] Delete any VolumeAttachments referencing Longhorn (best-effort)"
# k get volumeattachment -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.attacher}{"\n"}{end}' \
# | awk '$2 ~ /driver\.longhorn\.io/ {print $1}' \
# | xargs -r $KUBECTL delete volumeattachment >/dev/null 2>&1 || true

# echo ">>> [4] Delete all longhorn.io CRDs directly (garbage-collects their instances)"

# CRDS=$(k get crd -o name | grep -i 'longhorn\.io' || true)
# if [ -n "$CRDS" ]; then
#   echo "$CRDS" | xargs -r $KUBECTL delete --wait=false >/dev/null 2>&1 || true
# fi

# # Retry loop to remove CRD finalizers if stuck
# for attempt in 1 2 3 4 5; do
#   REM=$($KUBECTL get crd -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.group}{"\n"}{end}' 2>/dev/null | awk '$2=="longhorn.io"{print $1}')
#   [ -z "$REM" ] && break
#   echo "    attempt $attempt: removing CRD finalizers & re-deleting"
#   echo "$REM" | xargs -r -I{} $KUBECTL patch crd {} --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
#   echo "$REM" | xargs -r $KUBECTL delete --wait=false >/dev/null 2>&1 || true
#   sleep 2
# done

# echo ">>> [5] Final namespace cleanup"
# if k get ns longhorn-system >/dev/null; then
#   $KUBECTL patch namespace longhorn-system --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
#   $KUBECTL delete namespace longhorn-system --ignore-not-found >/dev/null 2>&1 || true
# fi

# echo ">>> [6] Optional local-node cleanup (this node only)"
# if command -v iscsiadm >/dev/null 2>&1; then
#   iscsiadm -m session >/dev/null 2>&1 || true
# fi

# # Unmount Longhorn volumes
# if [ "$ENV_TYPE" = "microk8s" ]; then
#   mount | grep -qi '/var/snap/microk8s/common/var/lib/longhorn' && \
#     sudo umount -lf /var/snap/microk8s/common/var/lib/longhorn 2>/dev/null || true
#   sudo rm -rf /var/snap/microk8s/common/var/lib/longhorn 2>/dev/null || true
# else
#   mount | grep -qi '/var/lib/longhorn' && \
#     sudo umount -lf /var/lib/longhorn 2>/dev/null || true
#   sudo rm -rf /var/lib/longhorn 2>/dev/null || true
# fi

# echo ">>> Verification:"
# $KUBECTL get sc 2>/dev/null | grep -i longhorn || echo "  ✓ no storageclasses"
# $KUBECTL get csidriver 2>/dev/null | grep -i longhorn || echo "  ✓ no csidrivers"
# $KUBECTL get crd 2>/dev/null | grep -i longhorn || echo "  ✓ no longhorn CRDs"
# $KUBECTL get ns longhorn-system >/dev/null 2>&1 || echo "  ✓ namespace gone"
# echo ">>> Longhorn ultra-cleanup complete."
# echo ""

# # -------------------- END --------------------
