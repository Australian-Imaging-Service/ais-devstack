#!/usr/bin/env bash
# ============================================================================
# Install the JupyterHub APPLICATION LAYER via the single `neurodesk` Helm chart.
# Replaces the old multi-chart JupyterHub-layer steps:
#   5-jupyterhub-values.yaml + 9-install-jupyterhub.sh   (JupyterHub)
#   6-cvmfs-mounts.sh + cvmfs_mount/                     (CVMFS + smarter-device-manager)
#   8-security-setup.sh + security/                      (Security Profiles Operator + AppArmor)
#   10-xnat-upload-extension.yaml                        (XNAT notebook extension)
#   ../../squid/                                         (CVMFS squid cache)
#
# Infrastructure is NOT installed here (it is consumed by name): Longhorn, NFS,
# ingress-nginx, cert-manager, the Prometheus stack, and the XNAT server are
# installed by their own (unchanged) steps before this runs.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="${NAMESPACE:-jupyter}"
RELEASE="${RELEASE:-neurodesk}"
CHART_REPO="${CHART_REPO:-https://github.com/neurodesk/helm-chart}"
CHART_REF="${CHART_REF:-main}"
CHART_PATH="${CHART_PATH:-}"            # set to a local chart checkout to skip cloning
VALUES="${VALUES:-$SCRIPT_DIR/values-devstack.yaml}"

echo "==> neurodesk JupyterHub-layer install (namespace=$NAMESPACE release=$RELEASE)"

# --- prerequisites the chart consumes (must already exist) ------------------
kubectl get sc longhorn >/dev/null 2>&1 || echo "  WARN: 'longhorn' StorageClass not found (hub DB + home PVCs need it)"
kubectl label node --all smarter-device-manager=enabled --overwrite >/dev/null 2>&1 || true

# --- obtain the chart -------------------------------------------------------
if [ -z "$CHART_PATH" ]; then
  CHART_PATH="$SCRIPT_DIR/.chart"
  if [ -d "$CHART_PATH/.git" ]; then
    git -C "$CHART_PATH" fetch --depth 1 origin "$CHART_REF" -q && git -C "$CHART_PATH" checkout -q FETCH_HEAD
  else
    rm -rf "$CHART_PATH"
    git clone --depth 1 -b "$CHART_REF" "$CHART_REPO" "$CHART_PATH"
  fi
fi
echo "  chart: $CHART_PATH"

# --- resolve dependencies (honors the chart's committed Chart.lock) ---------
# `helm dependency build` matches dependencies by repo URL. Register the EXACT
# URLs under chart-private names with --force-update, so a pre-existing repo
# that already claims the name `jupyterhub` (e.g. pointing at the old
# hub.jupyter.org URL) does not block resolution.
helm repo add nd-jupyterhub https://jupyterhub.github.io/helm-chart --force-update >/dev/null 2>&1 || true
helm repo add nd-smarter-device-manager https://smarter-project.github.io/smarter-device-manager --force-update >/dev/null 2>&1 || true
helm repo update nd-jupyterhub nd-smarter-device-manager >/dev/null 2>&1 || true
helm dependency build "$CHART_PATH"

# --- values -----------------------------------------------------------------
if [ ! -f "$VALUES" ]; then
  echo "ERROR: $VALUES not found. Copy values-devstack.yaml.template -> values-devstack.yaml and fill in the secrets." >&2
  exit 1
fi

# --- clear a known orphan from the legacy install (raw-kubectl ConfigMap) ---
kubectl -n "$NAMESPACE" delete configmap xnat-upload-extension --ignore-not-found >/dev/null 2>&1 || true

# --- install ----------------------------------------------------------------
helm upgrade --install "$RELEASE" "$CHART_PATH" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$VALUES" --timeout 15m

echo "==> done. Watch rollout:  kubectl -n $NAMESPACE get pods -w"
