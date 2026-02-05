# XNAT JupyterHub Plugin Configuration Guide

## Prerequisites
- JupyterHub installed and running
- XNAT JupyterHub plugin installed

## Step 1: Access XNAT Admin Interface

1. Login to XNAT as admin: http://xnat-test.ssdsorg.cloud.edu.au
2. Navigate to: **Administer** → **Plugin Settings** → **JupyterHub**

## Step 2: Configure JupyterHub Connection

### Basic Settings:

| Setting | Value |
|---------|-------|
| **JupyterHub API URL** | `http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api` |
| **JupyterHub Token** | `<whatever you have generated to authenticate the communication with xnat>` |
| **Path Translation XNAT to JupyterHub** | Enabled |
| **Start Timeout** | 300 (seconds) |
| **Stop Timeout** | 60 (seconds) |


## Step 3: Configure Compute Environment

Navigate to: **Administer** → **Plugin Settings** → **JupyterHub** → **Compute Environments**

Click **"Add Compute Environment"** and configure:

### Compute Environment Settings:

```yaml
Name: NeuroDesk
Description: NeuroDesk image with neuroimaging tools
Image: ghcr.io/neurodesk/neurodesktop/neurodesktop:2024-12-05
```

### Resource Limits:
```yaml
CPU Limit: 4
Memory Limit: 8G
CPU Guarantee: 0.5
Memory Guarantee: 1G
```

### Environment Variables:
```yaml
JUPYTER_ENABLE_LAB=yes
```

## Step 4: Configure Project-Level Settings

For each project that should have JupyterHub access:

1. Navigate to project: **Projects** → **[Your Project]**
2. Go to **Project Settings** → **JupyterHub**
3. Enable JupyterHub for the project
4. Select the Compute Environment: **NeuroDesk**

## Step 5: Test User Access Configuration

The plugin uses XNAT's Project/User permissions. Users will only see projects they have access to in XNAT.

### Expected API Response Format:

When JupyterHub calls XNAT API, XNAT should return:
```json
{
  "task_template": {
    "container_spec": {
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

## Step 6: User Workflow

### For End Users:

1. **Login to XNAT** with AAF credentials
2. **Navigate to a project** where JupyterHub is enabled
3. **Click "Launch JupyterHub"** button (appears in project actions)
4. **Browser redirects to JupyterHub**
   - AAF OAuth uses existing browser session
   - No re-login required!
5. **JupyterHub spawns notebook** with:
   - Personal workspace: `/home/jovyan` (10Gi persistent storage)
   - XNAT workspace: `/data/xnat/workspaces/users/{username}` (read-write)
   - XNAT workspace (alternate path): `/workspace/{username}` (read-write, same storage)
   - Project data: Dynamically mounted based on XNAT permissions (read-only)

**Note:** Build directory is NOT mounted in JupyterHub (only used by XNAT container service)


## Step 7: Verify Integration

### Test from XNAT UI:
1. Login as a test user
2. Navigate to a project with JupyterHub enabled
3. Click "Launch JupyterHub"
4. Should redirect to Jupyter Lab without additional complete login


## Step 8: Configure XNAT User Options API

XNAT needs to implement the user-options endpoint that JupyterHub calls.

The endpoint should be: `GET /xapi/jupyterhub/users/{username}/server/user-options`

This endpoint should:
1. Authenticate the request (Basic Auth with admin credentials)
2. Query XNAT database for user's accessible projects
3. Return JSON in XNAT's task_template format

### Example Implementation (pseudo-code):
```python
@GET
@Path("/jupyterhub/users/{username}/server/user-options")
def get_user_options(username):
    # Get user's accessible projects from XNAT
    projects = xnat.get_user_projects(username)
    
    mounts = []
    for project in projects:
        # Add archive mount for each accessible project
        mounts.append({
            "source": f"/data/xnat/archive/{project.id}/arc001",
            "target": f"/data/xnat/archive/{project.id}/arc001",
            "read_only": True
        })
    
    return {
        "task_template": {
            "container_spec": {
                "mounts": mounts,
                "env": {
                    "XNAT_USER": username,
                    "XNAT_HOST": "xnat-web.ais-xnat.svc.cluster.local"
                }
            },
            "resources": {
                "cpu_limit": 4,
                "mem_limit": "8G"
            }
        }
    }
```

**Key Points:**
- Uses XNAT's `task_template` structure (not flat JSON)
- Mounts use `source`/`target` format (not `project_id`)
- Workspace mounts are handled automatically by JupyterHub (don't include in API response)
