# XNAT JupyterHub Plugin Configuration Guide

## Automated Setup

Most configuration steps can be run automatically:

```bash
# Install plugin JAR and restart XNAT
./jupyterhub/0-xnat-jupyter-plugin.sh

# Configure plugin preferences, compute environment, and credentials
./jupyterhub/1-configure-xnat-jupyterhub.sh --password <admin_password>
```

The configuration script sets:
- JupyterHub API URL and service token
- Start/stop timeouts
- NeuroDesk compute environment image
- Path translation prefixes
- XNAT admin password in JupyterHub values

## Prerequisites
- JupyterHub installed and running
- XNAT JupyterHub plugin installed (0-xnat-jupyter-plugin.sh)
- XNAT admin password (set during XNAT setup wizard)

## Manual Setup (if needed)

### Step 1: Access XNAT Admin Interface

1. Login to XNAT as admin
2. Navigate to: **Administer** → **Plugin Settings** → **JupyterHub**

### Step 2: Configure JupyterHub Connection

| Setting | Value |
|---------|-------|
| **JupyterHub Host URL** | `https://<your-domain>` |
| **JupyterHub API URL** | `http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api` |
| **JupyterHub Token** | Service token from `5-jupyterhub-values.yaml` (hub.services.xnat-service.apiToken) |
| **Start Timeout** | 300 (seconds) |
| **Stop Timeout** | 60 (seconds) |

### Step 3: Compute Environments

The plugin auto-creates a default compute environment on first boot. Update it to use NeuroDesk:

Navigate to: **Administer** → **Plugin Settings** → **JupyterHub** → **Compute Environments**

```yaml
Name: NeuroDesk
Image: ghcr.io/neurodesk/neurodesktop/neurodesktop:2026-07-07
```

Hardware configs (Small/Medium/Large/XLarge) are auto-created by the plugin.

### Step 4: Enable JupyterHub Per-Project

For each project that should have JupyterHub access:

1. Navigate to: **Projects** → **[Your Project]**
2. Go to **Project Settings** → **JupyterHub**
3. Enable JupyterHub for the project
4. Select the Compute Environment: **NeuroDesk**

## REST API Reference

The configuration script uses these XNAT REST API endpoints:

### Preferences
```
GET  /xapi/jupyterhub/preferences              # Get all preferences
POST /xapi/jupyterhub/preferences              # Set preferences (JSON map)
POST /xapi/jupyterhub/preferences/{key}        # Set single preference
```

Key preference names:
- `jupyterHubHostUrl` - JupyterHub host URL
- `jupyterHubApiUrl` - JupyterHub API URL (internal)
- `jupyterHubToken` - Service authentication token
- `startTimeout` - Server start timeout (seconds)
- `stopTimeout` - Server stop timeout (seconds)
- `allUsersCanStartJupyter` - Allow all users to launch Jupyter
- `workspacePath` - XNAT workspace path
- `inactivityTimeout` - Idle timeout (minutes)
- `maxServerLifetime` - Max server lifetime (hours)
- `pathTranslationArchivePrefix` - XNAT archive path prefix
- `pathTranslationArchiveDockerPrefix` - Container archive path prefix
- `pathTranslationWorkspacePrefix` - XNAT workspace path prefix
- `pathTranslationWorkspaceDockerPrefix` - Container workspace path prefix

### Compute Environments
```
GET  /xapi/compute-environment-configs         # List compute environments
POST /xapi/compute-environment-configs         # Create compute environment
PUT  /xapi/compute-environment-configs/{id}    # Update compute environment
```

### Hardware Configs
```
GET  /xapi/hardware-configs                    # List hardware configs
POST /xapi/hardware-configs                    # Create hardware config
```

### Dashboard Configs (for project-level enabling)
```
GET  /xapi/jupyterhub/dashboards/configs                              # List all
POST /xapi/jupyterhub/dashboards/configs                              # Create
POST /xapi/jupyterhub/dashboards/configs/{id}/scope/site              # Enable site-wide
POST /xapi/jupyterhub/dashboards/configs/{id}/scope/project/{projId}  # Enable for project
```

## User Workflow

1. **Login to XNAT** with credentials
2. **Navigate to a project** where JupyterHub is enabled
3. **Click "Launch JupyterHub"** button (appears in project actions)
4. **Browser redirects to JupyterHub** (SSO - no re-login required)
5. **JupyterHub spawns NeuroDesk** with:
   - Personal workspace: `/home/jovyan` (10Gi persistent storage)
   - XNAT workspace: `/data/xnat/workspaces/users/{username}` (read-write)
   - XNAT workspace (alternate path): `/workspace/{username}` (read-write, same storage)
   - Project data: Dynamically mounted based on XNAT permissions (read-only)

**Note:** Build directory is NOT mounted in JupyterHub (only used by XNAT container service)

## Expected API Response Format

When JupyterHub's pre_spawn_hook calls XNAT, it expects:
```json
{
  "task_template": {
    "container_spec": {
      "image": "ghcr.io/neurodesk/neurodesktop/neurodesktop:2026-07-07",
      "mounts": [
        {
          "source": "/data/xnat/archive/PROJECT_ID/arc001",
          "target": "/data/xnat/archive/PROJECT_ID/arc001",
          "read_only": true
        }
      ],
      "env": {
        "XNAT_PROJECT": "PROJECT_ID"
      }
    },
    "resources": {
      "cpu_limit": 4,
      "mem_limit": "8G"
    }
  }
}
```

## Mount Path Mapping (xnat-mount-mapping ConfigMap)

XNAT's JupyterHub plugin returns mount sources as container-internal paths
(e.g., `/data/xnat/archive/proj_1`). However, XNAT uses custom subPath mappings
in its StatefulSet (see `manifests/kustomization.yaml`) that don't match the
actual NFS directory structure on the shared `/gpfs` volume.

The `xnat-mount-mapping` ConfigMap (`jupyterhub/2-xnat-mount-mapping.yaml`) bridges
this gap by mapping XNAT container paths to the real NFS subPaths.

### When to update the mapping

Every time you add a new project archive mount to `manifests/kustomization.yaml`,
you must also add the corresponding entry to `2-xnat-mount-mapping.yaml`.

### Example

If you add a new project in `kustomization.yaml`:
```yaml
- mountPath: /data/xnat/archive/proj_3
  name: xnat-gpfs
  subPath: uq03/pool03/proj_3/xnat
```

Add to `2-xnat-mount-mapping.yaml`:
```json
{
  "/data/xnat/archive/proj_1": "uq01/pool01/proj_1/xnat",
  "/data/xnat/archive/proj_2": "uq02/pool02/proj_2/xnat",
  "/data/xnat/archive/proj_3": "uq03/pool03/proj_3/xnat"
}
```

Then apply:
```bash
kubectl apply -f jupyterhub/2-xnat-mount-mapping.yaml
# Restart JupyterHub hub pod to pick up the new ConfigMap
kubectl rollout restart deployment/hub -n jupyter
```
