#!/usr/bin/env bash
# ============================================================================
# Uninstall the neurodesk JupyterHub-layer chart and clean its cluster-scoped
# leftovers. KEEPS infrastructure (Longhorn, NFS, ingress-nginx, cert-manager,
# the Prometheus stack, and the XNAT server) — those are torn down by the
# foundation scripts (../../scripts/uninstall.sh), not here.
# ============================================================================
set -uo pipefail
NAMESPACE="${NAMESPACE:-jupyter}"
RELEASE="${RELEASE:-neurodesk}"

echo "==> uninstalling neurodesk release '$RELEASE' from namespace '$NAMESPACE'"
helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null || echo "  (release not found)"

# Orphans / cluster-scoped objects Helm does not remove on uninstall:
echo "==> cleaning cluster-scoped leftovers (SPO CRDs/webhook/RBAC are cluster singletons)"
kubectl -n "$NAMESPACE" delete configmap xnat-upload-extension --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" delete pvc cvmfs --ignore-not-found >/dev/null 2>&1 || true   # chart recreates on reinstall

kubectl delete mutatingwebhookconfiguration spo-mutating-webhook-configuration >/dev/null 2>&1 || true
kubectl delete validatingwebhookconfiguration spo-validating-webhook-configuration >/dev/null 2>&1 || true
for crd in $(kubectl get crd 2>/dev/null | grep 'security-profiles-operator.x-k8s.io' | awk '{print $1}'); do
  # strip finalizers from any CR instances, then the CRD
  short="${crd%%.*}"
  for cr in $(kubectl get "$short" -A -o name 2>/dev/null); do
    kubectl patch "$cr" -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true
  done
  kubectl patch crd "$crd" -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true
  kubectl delete crd "$crd" --timeout=15s >/dev/null 2>&1 || true
done
kubectl get clusterrole,clusterrolebinding 2>/dev/null | grep -E '(spo-|security-profiles)' | awk '{print $1}' \
  | xargs -r kubectl delete >/dev/null 2>&1 || true

echo "==> neurodesk uninstalled (infrastructure left intact)."
