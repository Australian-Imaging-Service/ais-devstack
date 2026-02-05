# AIS-XNAT Deployment for k3s

XNAT deployment on k3s with NFS-backed storage for the Australian Imaging Service.

## Prerequisites

- Ubuntu 20.04+ or similar Linux distribution
- Minimum 4GB RAM, 2 CPU cores
- 600GB+ storage for NFS server
- Helm 3.x installed

## Directory Structure

```
ais-devstack/
├── README.md                    # This file
├── manifests/
│   ├── pv.yaml                  # Persistent Volumes (NFS-backed)
│   ├── pvc.yaml                 # Persistent Volume Claims
│   ├── configmap.yaml           # XNAT init script ConfigMap
│   ├── kustomization.yaml       # Kustomize patches for StatefulSet
│   ├── kustomize.sh             # Helm post-renderer script
│   └── values.yaml              # XNAT Helm chart values (domain config)
├── nfs-server/
│   └── values.yaml              # NFS server Helm chart values
├── plugins/
│   └── container-service-*.jar  # XNAT plugins (auto-copied during install)
├── jupyterhub/                  # JupyterHub integration (git subtree)
│   ├── INSTALL.sh               # JupyterHub orchestrator
│   ├── 5-jupyterhub-values.yaml.template  # JupyterHub config template
│   └── ...                      # See jupyterhub/README.md
└── scripts/
    ├── install.sh               # XNAT install (prompts for JupyterHub)
    ├── install-jupyterhub.sh    # JupyterHub installation
    ├── uninstall.sh             # XNAT uninstallation
    └── uninstall-jupyterhub.sh  # JupyterHub uninstallation
```

## Quick Start

### Install

```bash
cd /home/ubuntu/ais-devstack
chmod +x scripts/*.sh manifests/kustomize.sh
./scripts/install.sh
```

### Uninstall

The uninstall script automatically detects whether you're running MicroK8s or k3s:

```bash
./scripts/uninstall.sh
```

It will:
- Remove XNAT and related resources
- Optionally remove NFS server and CSI driver
- Optionally remove the entire Kubernetes distribution (MicroK8s or k3s)

## Manual Installation

If you prefer step-by-step installation:

### Step 1: Install k3s

```bash
curl -sfL https://get.k3s.io | sh -

# Configure kubectl
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
```

### Step 2: Install Helm (if not installed)

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Step 3: Install NGINX Ingress Controller

k3s comes with Traefik by default, but XNAT requires nginx-specific annotations for large file uploads:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.publishService.enabled=true
```

### Step 4: Install NFS CSI Driver

```bash
helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts

helm install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
  --namespace kube-system \
  --set kubeletDir=/var/lib/kubelet
```

### Step 5: Deploy NFS Server

```bash
kubectl create namespace storage

# Deploy using the nfs-server helm chart
helm install nfs-server ./nfs-server \
  --namespace storage \
  --values nfs-server/values.yaml

# Wait for pod to be ready
kubectl -n storage get pods -w

# Create required directories
kubectl -n storage exec deploy/nfs-server -- mkdir -p \
  /exports/gpfs /exports/xnat/data/build /exports/xnat/plugins
```

### Step 6: Deploy XNAT

```bash
# Create namespace
kubectl create namespace ais-xnat

# Apply storage resources
kubectl apply -f manifests/pv.yaml
kubectl apply -f manifests/pvc.yaml
kubectl apply -f manifests/configmap.yaml

# Add AIS Helm repo
helm repo add ais https://australian-imaging-service.github.io/charts
helm repo update

# Install XNAT with kustomize patches
chmod +x manifests/kustomize.sh
helm install xnat-web ais/xnat \
  --namespace ais-xnat \
  --values manifests/values.yaml \
  --post-renderer ./manifests/kustomize.sh
```

### Step 7: Verify Installation

```bash
# Watch pods start up
kubectl -n ais-xnat get pods -w

# Port forward to access locally
kubectl -n ais-xnat port-forward svc/xnat-web 8080:80
```

Access XNAT at http://localhost:8080 (default: admin/admin)

## Key Differences from MicroK8s

| Component | MicroK8s | k3s |
|-----------|----------|-----|
| Kubelet path | `/var/snap/microk8s/common/var/lib/kubelet` | `/var/lib/kubelet` |
| Default storage class | `microk8s-hostpath` | `local-path` |
| Default ingress | nginx (addon) | Traefik (requires nginx install) |
| kubectl | `microk8s kubectl` | `kubectl` |
| helm | `microk8s helm` | `helm` |
| Config location | Snap-based | `/etc/rancher/k3s/` |

## Configuration

### Ingress Host

Edit `manifests/values.yaml` to change the ingress hostname:

```yaml
xnat-web:
  ingress:
    hosts:
      - host: your-domain.example.com
```

### OpenID Authentication

Update the OpenID settings in `manifests/values.yaml`:

```yaml
xnat-web:
  plugins:
    openid-auth-plugin:
      - openid:
          aaf:
            clientId: "your-client-id"
            clientSecret: "your-client-secret"
```

### Storage Size

Edit `nfs-server/values.yaml`:

```yaml
persistence:
  size: 600Gi  # Adjust as needed
```

## Troubleshooting

### XNAT pod stuck in Init

```bash
kubectl -n ais-xnat describe pod xnat-web-0
kubectl -n ais-xnat logs xnat-web-0 -c home-init
```

### NFS connection issues

```bash
# Check NFS server is running
kubectl -n storage get pods
kubectl -n storage logs deploy/nfs-server

# Check PV/PVC binding
kubectl get pv
kubectl -n ais-xnat get pvc
```

### Database issues

```bash
kubectl -n ais-xnat logs xnat-web-0-postgresql-0
```

## Plugins

Plugins in the `plugins/` directory are automatically copied to the NFS server during installation.

**Pre-installed plugins:**
- `container-service-3.7.2-uq-fat.jar` - Container service plugin

**To add more plugins:**

1. Place JAR files in `plugins/` before running install, OR
2. Copy manually after installation:

```bash
# Copy plugin jar to NFS server
kubectl -n storage cp my-plugin.jar \
  $(kubectl -n storage get pods -l app=nfs-server -o name | cut -d/ -f2):/exports/xnat/plugins/

# Restart XNAT to load new plugins
kubectl -n ais-xnat rollout restart statefulset xnat-web
```

## JupyterHub Integration

JupyterHub provides interactive Jupyter notebooks integrated with XNAT. The `jupyterhub/` directory contains the JupyterHub deployment as a git subtree from [ais-jupyterhub](https://github.com/Australian-Imaging-Service/ais-jupyterhub).

### Install JupyterHub

**Option 1:** During XNAT installation, answer "y" when prompted:
```
Install JupyterHub? (y/N): y
```

**Option 2:** Install separately after XNAT is running:
```bash
./scripts/install-jupyterhub.sh
```

The install script automatically reads the domain from `manifests/values.yaml` and configures JupyterHub to use the same domain.

### Uninstall JupyterHub

```bash
./scripts/uninstall-jupyterhub.sh
```

### Update JupyterHub from Upstream

The `jupyterhub/` directory is a git subtree. To pull updates from the upstream ais-jupyterhub repository:

```bash
git subtree pull --prefix=jupyterhub \
  https://github.com/Australian-Imaging-Service/ais-jupyterhub.git \
  Development_AB --squash
```

To push local changes back to upstream (if you have write access):

```bash
git subtree push --prefix=jupyterhub \
  https://github.com/Australian-Imaging-Service/ais-jupyterhub.git \
  Development_AB
```

### JupyterHub Documentation

See the following files in `jupyterhub/` for more details:
- `README.md` - Architecture overview
- `XNAT-CONFIGURATION.md` - XNAT plugin setup
- `TROUBLESHOOTING.md` - Common issues and solutions
