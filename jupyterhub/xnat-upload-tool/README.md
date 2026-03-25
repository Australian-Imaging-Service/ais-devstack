# XNAT Upload Tool for JupyterHub

Interactive tool for uploading medical imaging data (DICOM, NIfTI, etc.) from JupyterHub to XNAT.

## What's New in v2.0.0

- **Alias Token Authentication**: Users authenticate with their personal XNAT alias tokens (no admin credentials exposed)
- **Flexible Upload Hierarchy**: Upload to any level (project, subject, session, or scan)
- **Upload Verification**: Automatic verification that files were successfully stored
- **Dynamic Hierarchy Indicator**: Visual feedback showing exactly where files will be stored

## Features

- **User-Based Authentication**: Each user uses their own XNAT alias tokens
- **Permission Checking**: Verifies write access to target XNAT project
- **Flexible Hierarchy**: Upload to project/subject/session/scan level based on your needs
- **DICOM Support**: Upload DICOM files to XNAT prearchive (with admin review workflow)
- **NIfTI Support**: Upload NIfTI and other processed files directly to archive
- **File Validation**: Basic validation of file formats and sizes
- **Interactive UI**: User-friendly form interface with ipywidgets
- **Upload Verification**: Confirms files exist in XNAT after upload

## Prerequisites

- Access to JupyterHub with NeuroDesk container
- XNAT account with appropriate project permissions
- XNAT Alias Token (generated from XNAT Profile page)
- Python packages: `ipywidgets`, `requests` (pre-installed in NeuroDesk)

## Quick Start

### Step 1: Generate Your XNAT Alias Token

1. Log into XNAT web interface
2. Click your username (top right) → **Profile**
3. Scroll to **Alias Tokens** section
4. Click **Create Alias Token**
5. Copy the **Alias** and **Secret** values

Example token:
```
Alias:  2777a4f6-468c-44d7-ab07-7a8c280b342c
Secret: 4ySxe8r58zUGGrBmfwe9vlSzr15meqrw66jcVJVE0PsxRyM732GNJF1zqEufrmdy
```

### Step 2: Copy Files to Your Workspace

Run this command in a JupyterHub terminal:

```bash
# Create directory in your workspace
mkdir -p /workspace/xnat-upload-tool

# Copy the upload tool files
# Option A: If files are in shared storage
cp -r /data/xnat/shared/xnat-upload-tool/* /workspace/xnat-upload-tool/

# Option B: Clone from git repository
cd /workspace
git clone https://github.com/Australian-Imaging-Service/ais-jupyterhub.git
cp -r ais-jupyterhub/xnat-upload-tool /workspace/
```

### Step 3: Open the Notebook

1. In Jupyter Lab, navigate to `/workspace/xnat-upload-tool/`
2. Open `XNAT_Upload_Tool.ipynb`
3. Run all cells in order

### Step 4: Use the Upload Form

1. Enter your XNAT alias token (Alias + Secret)
2. Click **"Validate Token"** to verify credentials
3. Fill in the metadata form:
   - **Project ID**: XNAT project identifier (required)
   - **Subject ID**: Subject/participant ID (optional)
   - **Session ID**: Imaging session ID (optional, requires Subject)
   - **Scan ID**: Scan number (optional, requires Session)
   - **File Type**: DICOM, NIfTI, or Other
4. Watch the **hierarchy indicator** to see where your file will be stored
5. Select files to upload (or provide file paths)
6. Click **"Check Permissions"** to verify access
7. Click **"Upload to XNAT"** to start upload

## Flexible Upload Hierarchy

The tool supports uploading to any level of the XNAT hierarchy:

| Fields Provided | Upload Location |
|-----------------|-----------------|
| Project only | `/projects/{project}/resources/` |
| Project + Subject | `/projects/{project}/subjects/{subject}/resources/` |
| Project + Subject + Session | `/projects/{project}/subjects/{subject}/experiments/{session}/resources/` |
| Project + Subject + Session + Scan | `/projects/{project}/.../scans/{scan}/resources/` |

The dynamic **hierarchy indicator** in the notebook shows exactly where your file will be stored based on the fields you've filled in.

## File Structure

```
xnat-upload-tool/
├── README.md                    # This file
├── xnat_uploader.py             # Python backend module (API integration)
├── XNAT_Upload_Tool.ipynb       # Interactive notebook UI
├── SECURITY_NOTES.md            # Security documentation
├── IMPLEMENTATION_SUMMARY.md    # Technical implementation details
└── examples/                    # (Future) Example notebooks
```

## Security & Authentication

### XNAT Alias Tokens

Alias tokens are user-specific authentication credentials:

- **Generated per-user** from XNAT Profile page
- **Can be revoked** individually without affecting other users
- **Stored securely** - secrets are masked in the UI
- **All uploads logged** under your XNAT username

### XNAT Roles Required for Upload

| Role          | Can Upload? | Notes                                      |
|---------------|-------------|--------------------------------------------|
| Owner         | Yes         | Full project access                        |
| Member        | Yes         | Can upload and modify data                 |
| Collaborator  | Yes         | Can upload data                            |
| Read-Only     | No          | View-only access                           |

### Authentication Flow

```
1. User generates alias token in XNAT (one-time setup)
2. User enters alias + secret in notebook
3. Tool validates token with XNAT API
4. Token used for all subsequent operations
5. Uploads logged under user's XNAT account
```

## Upload Workflows

### Workflow 1: DICOM Upload (via Prearchive)

**Recommended for raw DICOM data from scanners**

```
User selects DICOM files
    ↓
Tool zips files
    ↓
POST /data/services/import (with user's alias token)
    ↓
Files uploaded to XNAT prearchive
    ↓
Admin reviews in XNAT UI
    ↓
Admin archives session
    ↓
Data available in project
```

### Workflow 2: NIfTI/Other Upload (Direct to Archive)

**Recommended for processed data**

```
User selects NIfTI/other files
    ↓
PUT /data/archive/projects/{project}/.../files/{filename}
    ↓
Files uploaded directly to archive
    ↓
Upload verified with HEAD request
    ↓
Immediately available in project
```

## Usage Examples

### Example 1: Upload to Project Level

```python
# For data that belongs to the project but not a specific subject
Project ID: "BRAIN_STUDY"
Subject ID: (leave empty)
Session ID: (leave empty)
Scan ID: (leave empty)

# Result: File uploaded to /projects/BRAIN_STUDY/resources/FILES/
```

### Example 2: Upload to Subject Level

```python
# For subject-specific data without a specific session
Project ID: "BRAIN_STUDY"
Subject ID: "SUB001"
Session ID: (leave empty)
Scan ID: (leave empty)

# Result: File uploaded to /projects/BRAIN_STUDY/subjects/SUB001/resources/FILES/
```

### Example 3: Upload to Session Level

```python
# For session-level data (most common for processed results)
Project ID: "BRAIN_STUDY"
Subject ID: "SUB001"
Session ID: "MRI_20260115"
Scan ID: (leave empty)

# Result: File uploaded to .../experiments/MRI_20260115/resources/FILES/
```

### Example 4: Upload to Scan Level

```python
# For scan-specific processed data
Project ID: "BRAIN_STUDY"
Subject ID: "SUB001"
Session ID: "MRI_20260115"
Scan ID: "1"
Resource Label: NIFTI

# Result: File uploaded to .../scans/1/resources/NIFTI/
```

### Example 5: Python API Direct Usage

```python
from xnat_uploader import XNATUploader

uploader = XNATUploader()
uploader.set_credentials(
    alias="2777a4f6-468c-44d7-ab07-7a8c280b342c",
    secret="4ySxe8r58zUGGrBmfwe9vlSzr15meqrw66jcVJVE0PsxRyM732GNJF1zqEufrmdy"
)

# Validate token
result = uploader.validate_credentials()
if result['valid']:
    print(f"Authenticated as: {result['username']}")

# Upload to session level (subject + session, no scan)
result = uploader.upload_file(
    file_path="/workspace/output/result.nii.gz",
    project_id="BRAIN_STUDY",
    subject_id="SUB001",
    session_id="MRI_20260115",
    # scan_id omitted - uploads to session resources
    resource_label="PROCESSED",
    file_format="NIFTI"
)
print(result)
```

## API Reference

### `XNATUploader` Class

Main class for XNAT upload operations.

#### Methods

**`__init__(xnat_url=None)`**
- Initialize uploader with XNAT connection
- Defaults to `XNAT_URL` environment variable

**`set_credentials(alias, secret)`**
- Set user's XNAT alias token credentials
- Required before any operations

**`validate_credentials() → dict`**
- Validate alias token with XNAT
- Returns: `{'valid': bool, 'username': str, 'error': str}`

**`check_permissions(project_id) → dict`**
- Check if user has write access to project
- Returns: `{'has_permission': bool, 'role': str, 'user_info': dict}`

**`upload_file(file_path, project_id, subject_id=None, session_id=None, scan_id=None, ...) → dict`**
- Upload file to appropriate hierarchy level
- Optional parameters determine upload location
- Includes automatic upload verification

**`upload_dicom_to_prearchive(dicom_files, project_id, subject_id, session_id, ...) → dict`**
- Upload DICOM files to XNAT prearchive
- Returns: Upload result with prearchive session ID

## Troubleshooting

### Issue: "XNAT credentials not configured"

**Cause:** Alias token not entered or validated

**Solution:**
1. Enter your alias and secret in the credential fields
2. Click "Validate Token"
3. Wait for "Authenticated as: username" confirmation

### Issue: "Token validation failed"

**Cause:** Invalid alias token

**Solution:**
1. Generate a new alias token in XNAT (Profile → Alias Tokens)
2. Copy both Alias and Secret exactly
3. Check for extra spaces when pasting

### Issue: "Permission denied"

**Cause:** User doesn't have write access to project

**Solution:**
1. Contact XNAT administrator
2. Request Member or Collaborator role for the project

### Issue: "Upload verification failed"

**Cause:** File uploaded but not found at expected location

**Solution:**
1. Check XNAT web interface for the file
2. Verify project/subject/session/scan IDs are correct
3. Try uploading again with verbose logging

### Issue: "Network error / Connection timeout"

**Cause:** Cannot reach XNAT server

**Solution:**
1. Verify you're in a JupyterHub notebook
2. Check XNAT server is running
3. Contact administrator if issue persists

## Installation for Administrators

### Option 1: Deploy to Shared Workspace (Recommended)

```bash
# On the server with NFS access
sudo mkdir -p /exports/xnat/workspaces/shared/xnat-upload-tool
sudo cp xnat_uploader.py /exports/xnat/workspaces/shared/xnat-upload-tool/
sudo cp XNAT_Upload_Tool.ipynb /exports/xnat/workspaces/shared/xnat-upload-tool/
sudo chmod -R 755 /exports/xnat/workspaces/shared/xnat-upload-tool
```

### Option 2: ConfigMap Deployment (Kubernetes)

```bash
kubectl create configmap xnat-upload-tool \
  --from-file=xnat_uploader.py \
  --from-file=XNAT_Upload_Tool.ipynb \
  -n jupyter
```

## XNAT API Documentation

- **REST API Guide**: https://wiki.xnat.org/display/XAPI/XNAT+REST+API+Guide
- **Upload API**: https://wiki.xnat.org/display/XAPI/Uploading+Files+via+REST+API
- **Alias Tokens**: https://wiki.xnat.org/display/XAPI/How+to+Generate+Alias+Tokens

## Version History

- **v2.0.0** (2026-01-19): Alias token authentication, flexible hierarchy upload
- **v1.0.0** (2026-01-15): Initial release with admin credential authentication

## License

Copyright © Australian Imaging Service

## Authors

- Australian Imaging Service Team
- Version: 2.0.0
- Last Updated: 2026-01-19

## Support

For support, please contact:
- **Email**: support@australianimagingservice.org.au
- **GitHub Issues**: https://github.com/Australian-Imaging-Service/ais-jupyterhub/issues
- **XNAT Documentation**: https://wiki.xnat.org