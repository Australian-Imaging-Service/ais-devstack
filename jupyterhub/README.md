# JupyterHub-XNAT Integration

Complete integration of JupyterHub with XNAT on Kubernetes.

(Do a quick complete install by using: `./INSTALL.sh`)


**Important Note:** Replace `<username>`, `<jupyter-token>`, and domain names with your actual deployment values.

---

## 📋 Table of Contents
- [🏗️ Architecture Overview](#️-architecture-overview)
- [📦 Prerequisites](#-prerequisites)
- [🚀 Installation Steps](#-installation-steps)
- [⚙️ Configuration](#️-configuration)
- [🧪 Testing](#-testing)
- [👥 User Workflow](#-user-workflow)
- [🔒 Security](#-security)
- [🔧 Troubleshooting](#-troubleshooting)
- [📚 Additional Documentation](#-additional-documentation)
- [📄 License](#-license)
- [✅ Installation Checklist](#-installation-checklist)

---

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Internet / Users                         │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
              ┌────────────────┐
              │  Nginx Ingress │
              │  Controller    │
              └────┬──────┬────┘
                   │      │
        ┌──────────┘      └──────────┐
        ▼                            ▼
┌───────────────┐          ┌──────────────────┐
│     XNAT      │          │   JupyterHub     │
│               │◄─────────┤                  │
│  - AAF Auth   │  API     │  - AAF OAuth     │
│  - Projects   │  calls   │  - Spawner       │
│  - Plugin     │          │  - Hub           │
│               │          │  - User mapping  │
└───────┬───────┘          └────────┬─────────┘
        │                           │
        │                    ┌──────┴──────┐
        │                    │             │
        ▼                    ▼             ▼
┌───────────────┐    ┌──────────┐  ┌────────────┐
│  PostgreSQL   │    │   Hub    │  │   Proxy    │
│  (metadata)   │    │   DB     │  │  (route)   │
└───────────────┘    └──────────┘  └────────────┘
        │                               │
        │                               │
        ▼                               ▼
┌──────────────────────────────────────────────┐
│           User Notebook Pods                 │
│  ┌─────────────────────────────────────┐     │
│  │  /home/jovyan → Longhorn PVC        │     │
│  │  /data/projects/X → NFS subPath     │     │
│  │  /data/xnat/workspace → NFS         │     │
│  └─────────────────────────────────────┘     │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│          Storage Layer                       │
│  ┌──────────┐           ┌────────────┐       │
│  │ Longhorn │           │ NFS Server │       │
│  │  - User  │           │ /exports/  │       │
│  │   homes  │           │  - gpfs    │       │
│  │  - Hub DB│           │  - xnat    │       │
│  └──────────┘           └────────────┘       │
└──────────────────────────────────────────────┘
```

### Component Details

#### XNAT Layer
- **Purpose:** Medical imaging data management
- **Authentication:** AAF (Australian Access Federation) OAuth
- **Database:** PostgreSQL (metadata only)
- **Storage:** NFS (`/exports/gpfs`, `/exports/xnat`)
- **Plugin:** xnat-jupyterhub-plugin v1.1.1

#### JupyterHub Layer
- **Hub:** Central authentication and spawner
- **Proxy:** Routes traffic to user notebooks
- **Authentication:** AAF OAuth (shared session with XNAT)
- **API:** RESTful API for XNAT plugin
- **Spawner:** KubeSpawner with custom pre_spawn_hook

#### Storage Layer
- **Longhorn:**
  - Dynamic provisioning for user home directories
  - Hub database persistence
  - Block storage with replication

- **NFS:**
  - Shared storage for XNAT data
  - Read-only project data access
  - Read-write workspace directory

- **CVMFS:**
  - CVMFS CSI driver for repository access
  - Provides access to scientific software repositories
  - Mounted at `/cvmfs` in user notebooks
  - Uses smarter-device-manager for FUSE device access
  - Trace parser for metrics collection
  - Telegraf for InfluxDB to Prometheus conversion

#### Monitoring Layer
- **Prometheus Stack:**
  - Prometheus for metrics collection and alerting
  - Grafana for visualization (NodePort 31000)
  - AlertManager for alert routing
  - ServiceMonitor discovery from all namespaces

- **CVMFS Metrics:**
  - Trace parser reads CVMFS trace files
  - Exposes module usage metrics (`cvmfs_module_opens_total`)
  - Telegraf converts InfluxDB format to Prometheus
  - Combined metrics endpoint on port 9002

#### Security Layer
- **Security Profiles Operator (neurodesk fork):**
  - Manages AppArmor profiles for notebooks
  - Enforces container security policies
  - Prevents cryptocurrency mining and unauthorized processes
  - Automatic profile loading and enforcement

- **AppArmor Profiles:**
  - `notebook` profile applied to all user containers
  - Allows CVMFS access and required capabilities
  - Blocks known malicious binaries

#### Network Layer
- **Ingress:** Single entry point (`xnat-test.ssdsorg.cloud.edu.au`)
  - `/` → XNAT
  - `/jupyter` → JupyterHub

- **Internal Services:**
  - `xnat-web.ais-xnat.svc.cluster.local` (XNAT API)
  - `proxy-public.jupyter.svc.cluster.local` (JupyterHub API)

---

## 📦 Prerequisites

### Required
- ✅ Kubernetes cluster (microk8s 1.24+)
- ✅ kubectl configured
- ✅ Helm 3.x installed
- ✅ XNAT deployed with AAF authentication
- ✅ XNAT JupyterHub plugin installed
- ✅ NFS server with CSI driver
- ✅ Ingress controller (nginx)

### Minimum Resources
- **CPU:** 4 cores
- **Memory:** 8 GB RAM
- **Storage:** 100 GB available

### Network Requirements
- Port 80/443 accessible for ingress
- DNS configured for `<registered domain>`
- Internal cluster networking enabled

---

## 🚀 Installation Steps

### Step 0: Pre-Installation Check

Verify XNAT is running:
```bash
kubectl get pods -n ais-xnat
# Should show: xnat-web-0 (2/2 Running)
```

Verify NFS server is accessible:
```bash
kubectl get pods -n storage
# Should show: nfs-server-XXXXX (1/1 Running)
```

### Step 1: Cleanup Existing Installation

```bash
chmod +x 1-cleanup.sh
./1-cleanup.sh
```

This removes:
- Old JupyterHub installation
- Old Longhorn installation
- Security Profiles Operator
- CVMFS CSI driver
- Orphaned PVCs and PVs
- jupyter, security, and cvmfs namespaces

**Wait for cleanup to complete before proceeding.**

### Step 2: Install Longhorn

```bash
chmod +x 2-install-longhorn.sh
./2-install-longhorn.sh
```

Longhorn provides:
- Dynamic PVC provisioning
- Storage replication
- Snapshot capabilities
- Volume management UI
- Automatic BackupTarget configuration

**Expected time:** 3-5 minutes

### Step 3: Create Jupyter Namespace

```bash
kubectl create namespace jupyter
```

### Step 4: Create NFS PersistentVolume
```bash
kubectl apply -f 3-nfs-pv.yaml
```

Creates one PV:
- `jupyter-xnat-gpfs-shared` → Points to `/gpfs` on NFS for XNAT workspaces and project data

### Step 5: Create NFS PersistentVolumeClaim
```bash
kubectl apply -f 4-nfs-pvc.yaml
```

Creates one PVC in the jupyter namespace:
- `xnat-gpfs` → Binds to `jupyter-xnat-gpfs-shared` PV for mounting XNAT workspaces and project data

Verify binding:
```bash
kubectl get pvc -n jupyter
# Should show STATUS: Bound
```

### Step 6: Install CVMFS CSI Driver and Metrics

```bash
chmod +x 6-cvmfs-mounts.sh
./6-cvmfs-mounts.sh
```

This installs:
- CVMFS CSI driver for scientific software repositories
- smarter-device-manager for FUSE device access
- Node labels for device management
- CVMFS StorageClass configuration
- CVMFS trace parser for metrics collection
- Telegraf for InfluxDB to Prometheus conversion
- ServiceMonitor for Prometheus scraping

**Expected time:** 2-3 minutes

Verify:
```bash
kubectl get pods -n mounts -l app=smarter-device-manager
# Should show DaemonSet pods running on all nodes

kubectl get pods -n mounts -l app=cvmfs-trace-parser
# Should show trace parser pod running
```

### Step 7: Install Prometheus Monitoring Stack

```bash
chmod +x 7-monitoring.sh
./7-monitoring.sh
```

This installs:
- Prometheus for metrics collection
- Grafana for visualization (accessible at NodePort 31000)
- AlertManager for alerting
- ServiceMonitor discovery from all namespaces

**Expected time:** 5-10 minutes

Verify:
```bash
kubectl get pods -n monitoring
# Should show prometheus, grafana, alertmanager pods running
```

Access Grafana:
- URL: `http://<node-ip>:31000`
- Default credentials: admin / admin

### Step 8: Install Security Profiles Operator

```bash
chmod +x 8-security-setup.sh
./8-security-setup.sh
```

This installs:
- Security Profiles Operator (neurodesk fork with AppArmor support)
- AppArmor profile for notebook containers
- Automatic profile loading and enforcement

**Expected time:** 2-3 minutes

Verify AppArmor profile is ready:
```bash
kubectl get apparmorprofile -n security
# Should show: notebook   Installed   True
```

### Step 9: Install JupyterHub

```bash
chmod +x 9-install-jupyterhub.sh
./9-install-jupyterhub.sh
```

This installs:
- JupyterHub Hub (with custom pre_spawn_hook)
- Configurable HTTP Proxy
- User notebook spawner
- AAF OAuth configuration
- AppArmor profile enforcement
- CVMFS mount configuration

**Expected time:** 5-10 minutes

### Step 10: Verify Installation

Manual verification checks:
```bash
# Check JupyterHub
kubectl get pods -n jupyter

# Check Security Profiles
kubectl get apparmorprofile -n security

# Check CVMFS
kubectl get pods -n mounts -l app=smarter-device-manager
kubectl get pods -n mounts -l component=nodeplugin

# Check Longhorn
kubectl get pods -n longhorn-system
```

**All components should be running before proceeding.**

### Step 11: Configure XNAT Plugin

Follow detailed guide in `XNAT-CONFIGURATION.md`:

1. Login to XNAT admin interface
2. Configure JupyterHub connection settings
3. Set up compute environments
4. Enable JupyterHub for projects
5. Test user workflow

**Required Settings:**
- JupyterHub URL: `http://proxy-public.jupyter.svc.cluster.local/jupyter`
- Service Token: `<generated-service-token>`

---

## ⚙️ Configuration

### Key Configuration Files

#### 5-jupyterhub-values.yaml
Main JupyterHub configuration:
- AAF OAuth credentials
- Pre-spawn hook for XNAT integration
- Resource limits
- Storage configuration
- Image selection (NeuroDesk)

#### XNAT Plugin Settings
Configured via XNAT UI:
- JupyterHub API endpoint
- Service token
- Path translation
- Compute environments

### Customization Points

#### Change NeuroDesk Image Version
Edit `5-jupyterhub-values.yaml`:
```yaml
singleuser:
  image:
    name: ghcr.io/neurodesk/neurodesktop/neurodesktop
    tag: "2024-12-05"  # update to latest
```

#### Adjust User Resource Limits
Edit `5-jupyterhub-values.yaml`:
```yaml
singleuser:
  cpu:
    guarantee: 0.5  # Minimum CPU
    limit: 4        # Maximum CPU
  memory:
    guarantee: 1G   # Minimum RAM
    limit: 8G       # Maximum RAM
```

#### Change User Home Directory Size
Edit `5-jupyterhub-values.yaml`:
```yaml
singleuser:
  storage:
    capacity: 10Gi  # can change this to increase singleuser storage
```

#### Adjust Idle Timeout
Edit `5-jupyterhub-values.yaml`:
```yaml
cull:
  enabled: true
  timeout: 3600    # Seconds of inactivity (1 hour)
  every: 600       # Check interval (10 minutes)
```

### Monitoring Configuration

#### monitoring/values.yaml
Prometheus stack configuration:
- Prometheus server with 20Gi storage
- Grafana on NodePort 31000
- AlertManager for alerts
- ServiceMonitor discovery from all namespaces

#### Change Grafana Admin Password
Edit `monitoring/values.yaml`:
```yaml
grafana:
  adminPassword: your-secure-password
```

#### Adjust Prometheus Storage
Edit `monitoring/values.yaml`:
```yaml
prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 50Gi  # Increase for longer retention
```

#### Change Metrics Retention
Edit `monitoring/values.yaml`:
```yaml
prometheus:
  prometheusSpec:
    retention: 30d        # Keep metrics for 30 days
    retentionSize: "45GB" # Or limit by size
```

#### Access Monitoring

**Grafana Dashboard:**
```bash
# Direct access via NodePort
http://<node-ip>:31000
# Default credentials: admin / admin

# Or via port-forward
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Then access: http://localhost:3000
```

**Prometheus UI:**
```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Then access: http://localhost:9090
```

**CVMFS Metrics Endpoint:**
```bash
kubectl port-forward -n mounts svc/cvmfs-metrics 9002:9002
curl http://localhost:9002/metrics
```

---

## 🧪 Testing

### Test 1: API Connectivity

```bash
# From hub pod
HUB_POD=$(kubectl get pod -n jupyter -l component=hub -o jsonpath='{.items[0].metadata.name}')

# Test XNAT API
kubectl exec -n jupyter $HUB_POD -- \
  curl -u admin:admin \
  http://xnat-web.ais-xnat.svc.cluster.local/xnat/data/version

# Test JupyterHub API
kubectl exec -n jupyter $HUB_POD -- \
  curl -H "Authorization: token <jupyter-token>" \
  http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api
```

### Test 2: User Spawn

```bash
# Start test user's server
curl -X POST \
  -H "Authorization: token <jupyter-token>" \
  http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api/users/testuser/server

# Check pod creation
kubectl get pods -n jupyter | grep jupyter-<testuser>

# Check logs
kubectl logs -n jupyter jupyter-<testuser>
```

### Test 3: Data Access

Once user pod is running:
```bash
# Check mounts
kubectl exec -n jupyter jupyter-<testuser> -- df -h

# Check project data
kubectl exec -n jupyter jupyter-<testuser> -- ls -la /data/xnat/projects/

# Check home directory
kubectl exec -n jupyter jupyter-<testuser> -- ls -la /home/jovyan/
```

### Test 4: Monitoring

```bash
# Check Prometheus is scraping targets
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets | length'
# Should show number of active targets

# Check CVMFS metrics are available
kubectl port-forward -n mounts svc/cvmfs-metrics 9002:9002 &
curl -s http://localhost:9002/metrics | grep cvmfs
# Should show CVMFS metrics

# Access Grafana
# Open: http://<node-ip>:31000
# Login with: admin / admin
# Navigate to Explore → Select Prometheus → Query: cvmfs_module_opens_total

# Verify trace parser is running
kubectl logs -n mounts -l app=cvmfs-trace-parser -c parser --tail=10
# Should show parsing activity
```

---

## 👥 User Workflow

### For End Users

1. **Access XNAT**
   - Navigate to: http://xnat-test.ssdsorg.cloud.edu.au
   - Click "Login with AAF"
   - Enter AAF credentials

2. **Navigate to Project**
   - Select a project from project list
   - Ensure JupyterHub is enabled for the project

3. **Launch JupyterHub**
   - Click "Launch JupyterHub" button (in project actions)
   - Browser redirects to JupyterHub
   - **No full re-login required** (AAF session reused once correct Idp selected)

4. **Work in Notebook**
   - Jupyter Lab opens automatically
   - Personal workspace: `/home/jovyan`
   - Project data: `/data/projects/{PROJECT_ID}` (read-only)

5. **Save and Exit**
   - Work is automatically saved to personal storage
   - Server shuts down after set limit of inactivity


## 🔒 Security

### Authentication Flow

```
User → XNAT UI → "Launch Jupyter" button
  ↓
XNAT Plugin → JupyterHub API (service token)
  ↓
JupyterHub → Redirects to AAF OAuth
  ↓
AAF → Validates (reuses browser session)
  ↓
User → Redirected back to JupyterHub
  ↓
Pre-spawn hook → Calls XNAT API (admin credentials)
  ↓
XNAT API → Returns user's accessible projects
  ↓
Spawner → Mounts only authorized projects
  ↓
User Notebook → Launches with restricted access
```

### Security Best Practices

- ✅ Change default admin password in `5-jupyterhub-values.yaml`
- ✅ Rotate service token periodically
- ✅ Enable TLS for production (update ingress config)
- ✅ Implement NetworkPolicies for namespace isolation
- ✅ Regular security audits of pod configurations
- ✅ Monitor API access logs

### Secrets Management

Current secrets in configuration:
- AAF client_id and client_secret
- XNAT admin credentials
- JupyterHub service token

**For production:** Move to Kubernetes Secrets:
```bash
kubectl create secret generic jupyterhub-secrets -n jupyter \
  --from-literal=aaf-client-id='xxx' \
  --from-literal=aaf-client-secret='xxx' \
  --from-literal=xnat-admin-password='xxx'
```

---

## 🔧 Troubleshooting

See guide: `TROUBLESHOOTING.md`



---

## 📚 Additional Documentation

- **Installation:** This README
- **XNAT Configuration:** `XNAT-CONFIGURATION.md`
- **Troubleshooting:** `TROUBLESHOOTING.md`
- **Architecture Diagrams:** See above


---

## 📄 License

This integration follows the licenses of its components:
- JupyterHub: BSD License
- XNAT: Simplified BSD License
- Longhorn: Apache 2.0
- NeuroDesk: GPL-3.0

---

## ✅ Installation Checklist

Use this checklist to track your installation:

- [ ] Prerequisites verified
- [ ] Cleanup completed (`1-cleanup.sh`)
- [ ] Longhorn installed (`2-install-longhorn.sh`)
- [ ] Jupyter namespace created
- [ ] NFS PVs created (`3-nfs-pv.yaml`)
- [ ] NFS PVC created and bound (`4-nfs-pvc.yaml`)
- [ ] CVMFS CSI driver and metrics installed (`6-cvmfs-mounts.sh`)
- [ ] Prometheus monitoring stack installed (`7-monitoring.sh`)
- [ ] Security Profiles Operator installed (`8-security-setup.sh`)
- [ ] AppArmor profile verified (status: Installed)
- [ ] JupyterHub installed (`9-install-jupyterhub.sh`)
- [ ] All components verified (JupyterHub, Security, CVMFS, Longhorn, Monitoring)
- [ ] XNAT plugin configured (`XNAT-CONFIGURATION.md`)
- [ ] XNAT upload extension deployed (`10-xnat-upload-extension.yaml`)
- [ ] Test user workflow completed
- [ ] AppArmor enforcement verified in user pods
- [ ] CVMFS mount verified in user pods
- [ ] CVMFS metrics verified in Prometheus
- [ ] Production settings reviewed

---

**Version:** 1.1.0  
**Last Updated:** 04-12-2025  

