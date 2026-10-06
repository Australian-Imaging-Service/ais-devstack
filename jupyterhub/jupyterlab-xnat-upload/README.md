# JupyterLab XNAT Upload Extension

A JupyterLab extension for uploading medical imaging files (NIfTI, DICOM) and other data to XNAT archive servers.

## Features

- **Launcher Integration**: Access from JupyterLab launcher with custom icon
- **Secure Authentication**: Uses XNAT Alias Tokens (no shared passwords)
- **Permission-Based Projects**: Only shows projects where user has upload rights
- **Visual File Browser**: Browse workspace files with checkboxes for selection
- **Flexible Upload Hierarchy**: Upload to project, subject, session, or scan level
- **Auto File Format Detection**: Detects NIfTI, DICOM, CSV, and other formats
- **Upload Verification**: Confirms each file is stored in XNAT
- **Session Management**: Connect/disconnect with credential storage option

## Deployment

This extension is deployed via Kubernetes ConfigMap and JupyterHub Helm values. No build process is required.

### Prerequisites

- Kubernetes cluster with JupyterHub deployed via Helm
- Access to modify JupyterHub Helm values
- XNAT server accessible from the JupyterHub pods

### Step 1: Apply the ConfigMap

The extension code is contained in `10-xnat-upload-extension.yaml`. Apply it to your cluster:

```bash
kubectl apply -f 10-xnat-upload-extension.yaml -n jupyter
```

This ConfigMap contains:
- `handlers.py` - REST API handlers for XNAT operations
- `__init__.py` - Extension entry point
- `neurodesk_server.py` - Standalone HTTP server with full UI
- `xnat_icon.svg` - Launcher icon

### Step 2: Configure JupyterHub Helm Values

Add the following to your JupyterHub Helm values file (e.g., `5-jupyterhub-values.yaml`):

#### Mount the ConfigMap in singleuser pods:

```yaml
singleuser:
  storage:
    extraVolumes:
      - name: xnat-upload-extension
        configMap:
          name: xnat-upload-extension
          defaultMode: 0755
    extraVolumeMounts:
      - name: xnat-upload-extension
        mountPath: /opt/xnat-upload-extension
```

#### Install required Python packages via init container:

```yaml
singleuser:
  initContainers:
    - name: install-xnat-deps
      image: python:3.11-slim
      command:
        - /bin/bash
        - -c
        - |
          pip install --target=/opt/conda-packages xnat requests fileformats fileformats-medimage
      volumeMounts:
        - name: conda-packages
          mountPath: /opt/conda-packages
```

#### Configure ServerProxy for launcher integration:

```yaml
singleuser:
  extraFiles:
    jupyter_server_config:
      mountPath: /etc/jupyter/jupyter_server_config.py
      stringData: |
        # Keep existing ServerProxy servers and add XNAT Upload
        c.ServerProxy.servers.update({
            'xnat-upload': {
                'command': ['python3', '/opt/xnat-upload-extension/neurodesk_server.py', '--port', '{port}'],
                'port': 5050,
                'timeout': 30,
                'launcher_entry': {
                    'enabled': True,
                    'title': 'XNAT Upload',
                    'icon_path': '/opt/xnat-upload-extension/xnat_icon.svg'
                }
            }
        })
```

**Important**: Use `c.ServerProxy.servers.update({...})` instead of `c.ServerProxy.servers = {...}` to preserve other launcher entries (RStudio, etc.).

### Step 3: Deploy with Helm

```bash
helm upgrade --install jupyterhub jupyterhub/jupyterhub \
  -f 5-jupyterhub-values.yaml \
  -n jupyter
```

### Step 4: Restart User Pods

Existing user pods need to be restarted to pick up the changes:

```bash
# Delete existing user pods (they will recreate on next login)
kubectl delete pods -l component=singleuser-server -n jupyter
```

## Usage

### 1. Get Your XNAT Alias Token

1. Log into the XNAT web interface
2. Click your username (top right) → **Manage Alias Tokens**
3. Click **Create Alias**
4. Copy the **Alias** and **Secret** values

### 2. Connect to XNAT

1. Open JupyterLab and click **XNAT Upload** in the launcher
2. Enter your Alias and Secret
3. Optionally check "Remember credentials"
4. Click **Connect to XNAT**

### 3. Select Project

Choose a project from the dropdown. Only projects where you have upload permissions (Owner, Member, or Collaborator) are shown.

### 4. Configure Upload Location

| Fields Provided | Upload Location |
|-----------------|-----------------|
| Project only | Project → Resources |
| Project + Subject | Subject → Resources |
| Project + Subject + Session | Session → Resources |
| All fields + Scan | Scan → Resources |

- **Subject**: Enter existing subject ID or new ID to create
- **Session**: Enter existing session label or new label to create
- **Scan**: Enter scan ID (creates if doesn't exist)
- **Resource Label**: Container name for files (default: "FILES")

### 5. Select Files

Three ways to select files:

- **Browse**: Click folders to navigate, check files to select
- **Quick Access**: Use buttons for common directories (/workspace, /home, etc.)
- **Manual Path**: Type a path and click "Add"

Selected files appear below with file format badges. Click ✕ to remove individual files or "Clear All" to remove all.

### 6. Upload

Click **Upload to XNAT** and monitor progress. Results show success or failure for each file with detailed messages.

## File Access

The extension can access files in these directories:
- `/workspace` - User workspace
- `/home/jovyan` - Home directory
- `/neurodesktop-storage` - Shared storage
- `/data` - Data directory
- `/tmp` - Temporary files

## Security

### Authentication
- Uses XNAT Alias Tokens, not passwords
- Each user authenticates with their own token
- Tokens can be revoked in XNAT at any time

### Permission Filtering
- Only shows projects where user has upload rights
- Checks user role via XNAT API (Owner, Member, Collaborator)
- Prevents uploads to projects without proper access

### Credential Storage
- Optional browser localStorage storage
- Credentials cleared on disconnect
- Users control whether to remember credentials

## Troubleshooting

### Extension not appearing in launcher

1. Check ConfigMap is applied:
   ```bash
   kubectl get configmap xnat-upload-extension -n jupyter
   ```

2. Check pod has the volume mounted:
   ```bash
   kubectl exec -it <pod-name> -n jupyter -- ls -la /opt/xnat-upload-extension/
   ```

3. Restart the user pod to pick up changes

### Connection failed

- Verify alias token is valid and not expired
- Check XNAT server is accessible from the pod
- Create a new token in XNAT if needed

### No projects appearing

- Ensure you have upload permissions on at least one project
- Contact your XNAT administrator to be added as Member or Collaborator

### Upload failed

- Check file exists and is readable
- Verify subject/session IDs don't contain special characters
- Check XNAT server logs for detailed errors

## Requirements

- JupyterHub with jupyter-server-proxy installed
- Python packages: `xnat`, `requests`, `fileformats`, `fileformats-medimage`
- XNAT server (tested with XNAT 1.7+)

## License

MIT License - Australian Imaging Service

## Support

- GitHub Issues: Report bugs and feature requests
- XNAT Documentation: https://wiki.xnat.org
- xnatpy Documentation: https://xnat.readthedocs.io
