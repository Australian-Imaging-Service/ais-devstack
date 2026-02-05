#!/usr/bin/env python3
"""
Standalone XNAT Upload Server for Neurodesk

This server provides a web interface for uploading files to XNAT.
It can be discovered by the Neurodesk webapp wrapper system.

Usage:
    python3 server.py [--port PORT]

Default port: 5050
"""

import os
import sys
import json
import argparse
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import mimetypes

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / 'jupyterlab_xnat_upload'))
sys.path.insert(0, str(Path(__file__).parent.parent.parent / 'xnat-upload-tool'))

try:
    from xnat_uploader import XNATUploader, XNATUploadError
except ImportError:
    print("Warning: xnat_uploader module not found. Upload functionality will be limited.")
    XNATUploader = None
    XNATUploadError = Exception

# Configuration
DEFAULT_PORT = 5050
STATIC_DIR = Path(__file__).parent / 'static'
ALLOWED_PATHS = [
    '/workspace',
    '/home/jovyan',
    '/neurodesktop-storage',
    '/data',
    '/tmp',
    str(Path.home()),
]

# Global uploader instance
uploader = None


class XNATUploadHandler(BaseHTTPRequestHandler):
    """HTTP handler for XNAT upload web interface."""

    def log_message(self, format, *args):
        """Log to stdout."""
        print(f"[{self.log_date_time_string()}] {format % args}")

    def send_json(self, data, status=200):
        """Send JSON response."""
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def send_error_json(self, message, status=400):
        """Send error JSON response."""
        self.send_json({'error': message, 'success': False}, status)

    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_GET(self):
        """Handle GET requests."""
        parsed = urlparse(self.path)
        path = parsed.path

        # API endpoints
        if path == '/api/projects':
            self.handle_get_projects()
        elif path == '/api/files':
            self.handle_list_files(parsed.query)
        elif path == '/api/session':
            self.handle_get_session()
        elif path == '/api/allowed-paths':
            self.send_json({'paths': ALLOWED_PATHS, 'success': True})
        elif path == '/' or path == '/index.html':
            self.serve_index()
        else:
            self.serve_static(path)

    def do_POST(self):
        """Handle POST requests."""
        parsed = urlparse(self.path)
        path = parsed.path

        # Read body
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length) if content_length > 0 else b''

        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            return self.send_error_json('Invalid JSON')

        # API endpoints
        if path == '/api/auth':
            self.handle_auth(data)
        elif path == '/api/permissions':
            self.handle_permissions(data)
        elif path == '/api/upload':
            self.handle_upload(data)
        elif path == '/api/disconnect':
            self.handle_disconnect()
        else:
            self.send_error_json('Not found', 404)

    def serve_index(self):
        """Serve the main HTML page."""
        html = self.generate_index_html()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.end_headers()
        self.wfile.write(html.encode())

    def serve_static(self, path):
        """Serve static files."""
        # Security: prevent directory traversal
        safe_path = Path(path.lstrip('/'))
        file_path = STATIC_DIR / safe_path

        if not file_path.exists() or not file_path.is_file():
            self.send_error(404, 'File not found')
            return

        mime_type, _ = mimetypes.guess_type(str(file_path))
        self.send_response(200)
        self.send_header('Content-Type', mime_type or 'application/octet-stream')
        self.end_headers()
        self.wfile.write(file_path.read_bytes())

    def handle_auth(self, data):
        """Handle authentication."""
        global uploader

        alias = data.get('alias', '').strip()
        secret = data.get('secret', '').strip()

        if not alias or not secret:
            return self.send_error_json('Alias and secret are required')

        if XNATUploader is None:
            return self.send_error_json('XNAT uploader module not available')

        xnat_url = os.environ.get('XNAT_URL', 'http://xnat-web.ais-xnat.svc.cluster.local')
        uploader = XNATUploader(xnat_url=xnat_url)
        uploader.set_credentials(alias, secret)

        result = uploader.validate_credentials()

        if result['valid']:
            self.send_json({
                'valid': True,
                'username': result['username'],
                'xnat_url': uploader.xnat_url,
                'success': True
            })
        else:
            self.send_json({
                'valid': False,
                'error': result.get('error', 'Authentication failed'),
                'success': False
            }, 401)

    def handle_get_projects(self):
        """Get accessible projects."""
        global uploader

        if uploader is None or not uploader.authenticated_user:
            return self.send_error_json('Not authenticated', 401)

        try:
            projects = uploader.get_accessible_projects(writable_only=True)
            self.send_json({'projects': projects, 'success': True})
        except Exception as e:
            self.send_error_json(str(e), 500)

    def handle_permissions(self, data):
        """Check project permissions."""
        global uploader

        if uploader is None or not uploader.authenticated_user:
            return self.send_error_json('Not authenticated', 401)

        project_id = data.get('project_id', '').strip()
        if not project_id:
            return self.send_error_json('project_id is required')

        try:
            result = uploader.check_permissions(project_id)
            result['success'] = True
            self.send_json(result)
        except Exception as e:
            self.send_error_json(str(e), 500)

    def handle_list_files(self, query_string):
        """List files in a directory."""
        params = parse_qs(query_string)
        path = params.get('path', [''])[0]
        absolute = params.get('absolute', ['false'])[0].lower() == 'true'

        # Determine base path
        if absolute and path:
            full_path = Path(path)
        else:
            # Default to home directory
            base_path = Path.home()
            full_path = base_path / path if path else base_path

        # Security check
        try:
            resolved = full_path.resolve()
            allowed = any(str(resolved).startswith(p) for p in ALLOWED_PATHS)
            if not allowed:
                return self.send_error_json(f'Path not allowed. Allowed: {", ".join(ALLOWED_PATHS)}')
        except Exception:
            return self.send_error_json('Invalid path')

        if not full_path.exists():
            return self.send_error_json('Path not found', 404)

        if not full_path.is_dir():
            return self.send_error_json('Not a directory')

        files = []
        try:
            for item in sorted(full_path.iterdir()):
                if item.name.startswith('.'):
                    continue

                file_info = {
                    'name': item.name,
                    'path': str(item),
                    'type': 'directory' if item.is_dir() else 'file'
                }

                if item.is_file():
                    try:
                        file_info['size'] = item.stat().st_size
                        file_info['format'] = self.detect_format(item)
                    except Exception:
                        file_info['size'] = 0
                        file_info['format'] = 'OTHER'

                files.append(file_info)
        except PermissionError:
            return self.send_error_json('Permission denied')

        self.send_json({
            'path': str(full_path),
            'files': files,
            'allowed_roots': ALLOWED_PATHS,
            'success': True
        })

    def detect_format(self, path):
        """Detect file format from extension."""
        name = path.name.lower()
        if name.endswith('.nii.gz') or name.endswith('.nii'):
            return 'NIFTI'
        if name.endswith('.dcm') or name.endswith('.dicom'):
            return 'DICOM'

        ext_map = {
            '.csv': 'CSV', '.tsv': 'TSV', '.txt': 'TEXT', '.json': 'JSON',
            '.xml': 'XML', '.png': 'PNG', '.jpg': 'JPEG', '.jpeg': 'JPEG',
            '.pdf': 'PDF', '.zip': 'ZIP', '.tar': 'TAR', '.mat': 'MATLAB',
        }
        return ext_map.get(path.suffix.lower(), 'OTHER')

    def handle_upload(self, data):
        """Upload files to XNAT."""
        global uploader

        if uploader is None or not uploader.authenticated_user:
            return self.send_error_json('Not authenticated', 401)

        files = data.get('files', [])
        project_id = data.get('project_id', '').strip()

        if not files:
            return self.send_error_json('files array is required')
        if not project_id:
            return self.send_error_json('project_id is required')

        subject_id = data.get('subject_id', '').strip() or None
        session_id = data.get('session_id', '').strip() or None
        scan_id = data.get('scan_id', '').strip() or None
        resource_label = data.get('resource_label', 'FILES').strip()
        session_type = data.get('session_type', 'xnat:mrSessionData')
        scan_type = data.get('scan_type', 'OTHER')
        verify_upload = data.get('verify_upload', True)

        # Validate hierarchy
        if scan_id and not session_id:
            return self.send_error_json('scan_id requires session_id')
        if session_id and not subject_id:
            return self.send_error_json('session_id requires subject_id')

        results = []
        success_count = 0
        fail_count = 0

        for file_path_str in files:
            file_path = Path(file_path_str)

            # Security check
            try:
                resolved = file_path.resolve()
                allowed = any(str(resolved).startswith(p) for p in ALLOWED_PATHS)
                if not allowed:
                    results.append({
                        'file': file_path_str,
                        'status': 'failed',
                        'error': 'File path not allowed'
                    })
                    fail_count += 1
                    continue
            except Exception:
                pass

            if not file_path.exists():
                results.append({
                    'file': file_path_str,
                    'status': 'failed',
                    'error': 'File not found'
                })
                fail_count += 1
                continue

            file_format = self.detect_format(file_path)

            try:
                if file_format == 'DICOM' and subject_id and session_id:
                    result = uploader.upload_dicom_to_prearchive(
                        dicom_files=[file_path],
                        project_id=project_id,
                        subject_id=subject_id,
                        session_id=session_id
                    )
                    results.append({
                        'file': file_path.name,
                        'status': 'success',
                        'location': 'Prearchive',
                        'format': file_format
                    })
                else:
                    result = uploader.upload_file(
                        file_path=file_path,
                        project_id=project_id,
                        subject_id=subject_id,
                        session_id=session_id,
                        scan_id=scan_id,
                        resource_label=resource_label,
                        file_format=file_format,
                        session_type=session_type if session_id else None,
                        scan_type=scan_type,
                        verify_upload=verify_upload
                    )
                    results.append({
                        'file': file_path.name,
                        'status': 'success',
                        'location': result.get('location', 'Archive'),
                        'verified': result.get('verified', False),
                        'format': file_format
                    })

                success_count += 1

            except Exception as e:
                results.append({
                    'file': file_path.name,
                    'status': 'failed',
                    'error': str(e),
                    'format': file_format
                })
                fail_count += 1

        self.send_json({
            'results': results,
            'summary': {
                'total': len(files),
                'success': success_count,
                'failed': fail_count
            },
            'success': fail_count == 0
        })

    def handle_get_session(self):
        """Get session info."""
        global uploader

        if uploader is None:
            self.send_json({
                'connected': False,
                'success': True
            })
        else:
            try:
                info = uploader.get_session_info()
                info['success'] = True
                self.send_json(info)
            except Exception as e:
                self.send_json({
                    'connected': False,
                    'error': str(e),
                    'success': False
                })

    def handle_disconnect(self):
        """Disconnect from XNAT."""
        global uploader

        if uploader:
            uploader.disconnect()
            uploader = None

        self.send_json({'success': True, 'message': 'Disconnected'})

    def generate_index_html(self):
        """Generate the main HTML page."""
        return '''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>XNAT Upload</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f5f5f5; color: #333; }
        .container { max-width: 900px; margin: 0 auto; padding: 20px; }
        h1 { color: #2196f3; margin-bottom: 20px; }
        .card { background: white; border-radius: 8px; padding: 20px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .card h2 { font-size: 1.2em; margin-bottom: 15px; color: #555; }
        .form-group { margin-bottom: 15px; }
        .form-group label { display: block; margin-bottom: 5px; font-weight: 500; }
        .form-group input, .form-group select { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 4px; font-size: 14px; }
        .form-row { display: flex; gap: 15px; }
        .form-row .form-group { flex: 1; }
        .btn { padding: 10px 20px; border: none; border-radius: 4px; cursor: pointer; font-size: 14px; }
        .btn-primary { background: #2196f3; color: white; }
        .btn-success { background: #4caf50; color: white; }
        .btn-danger { background: #f44336; color: white; }
        .btn:disabled { opacity: 0.5; cursor: not-allowed; }
        .status { padding: 10px; border-radius: 4px; margin-top: 10px; }
        .status.success { background: #e8f5e9; color: #2e7d32; }
        .status.error { background: #ffebee; color: #c62828; }
        .file-list { max-height: 300px; overflow-y: auto; border: 1px solid #ddd; border-radius: 4px; }
        .file-item { padding: 10px; border-bottom: 1px solid #eee; display: flex; align-items: center; gap: 10px; }
        .file-item:last-child { border-bottom: none; }
        .file-item.directory { cursor: pointer; background: #fafafa; }
        .file-item.directory:hover { background: #f0f0f0; }
        .file-item input[type="checkbox"] { flex-shrink: 0; }
        .file-name { flex: 1; }
        .file-format { font-size: 12px; padding: 2px 6px; border-radius: 3px; background: #e3f2fd; color: #1976d2; }
        .file-size { font-size: 12px; color: #999; }
        .breadcrumb { padding: 10px; background: #fafafa; border-radius: 4px; margin-bottom: 10px; }
        .breadcrumb span { cursor: pointer; color: #2196f3; }
        .breadcrumb span:hover { text-decoration: underline; }
        .quick-nav { margin-bottom: 10px; }
        .quick-nav button { margin-right: 5px; padding: 5px 10px; font-size: 12px; }
        .hidden { display: none; }
        #results { margin-top: 20px; }
        .result-item { padding: 10px; margin: 5px 0; border-radius: 4px; }
        .result-item.success { background: #e8f5e9; }
        .result-item.failed { background: #ffebee; }
    </style>
</head>
<body>
    <div class="container">
        <h1>XNAT Upload</h1>

        <!-- Authentication -->
        <div class="card" id="auth-card">
            <h2>Authentication</h2>
            <div class="form-row">
                <div class="form-group">
                    <label>Alias Token</label>
                    <input type="text" id="alias" placeholder="Enter your XNAT alias token">
                </div>
                <div class="form-group">
                    <label>Secret</label>
                    <input type="password" id="secret" placeholder="Enter your secret">
                </div>
            </div>
            <button class="btn btn-primary" onclick="authenticate()">Connect</button>
            <button class="btn btn-danger hidden" id="disconnect-btn" onclick="disconnect()">Disconnect</button>
            <div id="auth-status" class="status hidden"></div>
        </div>

        <!-- Upload Form (hidden until authenticated) -->
        <div class="card hidden" id="upload-card">
            <h2>Upload Configuration</h2>
            <div class="form-group">
                <label>Project</label>
                <select id="project"><option value="">-- Select Project --</option></select>
            </div>
            <div class="form-row">
                <div class="form-group">
                    <label>Subject ID (optional)</label>
                    <input type="text" id="subject" placeholder="e.g., SUBJ001">
                </div>
                <div class="form-group">
                    <label>Session ID (optional)</label>
                    <input type="text" id="session" placeholder="e.g., SESS001">
                </div>
            </div>
            <div class="form-row">
                <div class="form-group">
                    <label>Scan ID (optional)</label>
                    <input type="text" id="scan" placeholder="e.g., 1">
                </div>
                <div class="form-group">
                    <label>Resource Label</label>
                    <input type="text" id="resource" value="FILES" placeholder="e.g., FILES, NIFTI">
                </div>
            </div>
            <div class="form-row">
                <div class="form-group">
                    <label>Modality</label>
                    <select id="modality">
                        <option value="xnat:mrSessionData">MR (Magnetic Resonance)</option>
                        <option value="xnat:ctSessionData">CT (Computed Tomography)</option>
                        <option value="xnat:petSessionData">PET (Positron Emission Tomography)</option>
                        <option value="xnat:crSessionData">CR (Computed Radiography)</option>
                    </select>
                </div>
                <div class="form-group">
                    <label>Scan Type</label>
                    <input type="text" id="scantype" value="OTHER" placeholder="e.g., T1, T2, FLAIR">
                </div>
            </div>
        </div>

        <!-- File Browser (hidden until authenticated) -->
        <div class="card hidden" id="files-card">
            <h2>Select Files</h2>
            <div class="quick-nav" id="quick-nav"></div>
            <div class="breadcrumb" id="breadcrumb"></div>
            <div class="file-list" id="file-list"></div>
            <div style="margin-top: 15px;">
                <input type="text" id="manual-path" placeholder="Or enter file path manually..." style="width: calc(100% - 80px);">
                <button class="btn btn-primary" onclick="addManualPath()" style="width: 70px;">Add</button>
            </div>
            <div style="margin-top: 15px;">
                <strong>Selected: <span id="selected-count">0</span> file(s)</strong>
            </div>
            <button class="btn btn-success" style="margin-top: 15px; width: 100%;" onclick="uploadFiles()">Upload to XNAT</button>
        </div>

        <!-- Results -->
        <div id="results"></div>
    </div>

    <script>
        let currentPath = '';
        let selectedFiles = [];
        let allowedRoots = [];

        async function api(endpoint, method = 'GET', body = null) {
            const opts = { method, headers: { 'Content-Type': 'application/json' } };
            if (body) opts.body = JSON.stringify(body);
            const res = await fetch('/api/' + endpoint, opts);
            return res.json();
        }

        async function authenticate() {
            const alias = document.getElementById('alias').value;
            const secret = document.getElementById('secret').value;
            const status = document.getElementById('auth-status');

            status.className = 'status';
            status.textContent = 'Connecting...';
            status.classList.remove('hidden');

            const res = await api('auth', 'POST', { alias, secret });

            if (res.valid) {
                status.className = 'status success';
                status.textContent = 'Connected as: ' + res.username;
                document.getElementById('disconnect-btn').classList.remove('hidden');
                document.getElementById('upload-card').classList.remove('hidden');
                document.getElementById('files-card').classList.remove('hidden');
                loadProjects();
                loadFiles('');
            } else {
                status.className = 'status error';
                status.textContent = res.error || 'Authentication failed';
            }
        }

        async function disconnect() {
            await api('disconnect', 'POST');
            document.getElementById('auth-status').className = 'status hidden';
            document.getElementById('disconnect-btn').classList.add('hidden');
            document.getElementById('upload-card').classList.add('hidden');
            document.getElementById('files-card').classList.add('hidden');
            document.getElementById('results').innerHTML = '';
            selectedFiles = [];
        }

        async function loadProjects() {
            const res = await api('projects');
            const select = document.getElementById('project');
            select.innerHTML = '<option value="">-- Select Project --</option>';
            if (res.projects) {
                res.projects.forEach(p => {
                    select.innerHTML += `<option value="${p.id}">${p.id} - ${p.name} (${p.role})</option>`;
                });
            }
        }

        async function loadFiles(path, absolute = false) {
            const res = await api('files?path=' + encodeURIComponent(path) + '&absolute=' + absolute);
            if (!res.success) {
                alert(res.error);
                return;
            }

            currentPath = res.path;
            allowedRoots = res.allowed_roots || [];
            updateBreadcrumb();
            updateQuickNav();

            const list = document.getElementById('file-list');
            list.innerHTML = '';

            // Parent directory
            if (currentPath !== '/') {
                const parent = document.createElement('div');
                parent.className = 'file-item directory';
                parent.innerHTML = '<span class="file-name">..</span>';
                parent.onclick = () => {
                    const parts = currentPath.split('/').filter(Boolean);
                    parts.pop();
                    loadFiles('/' + parts.join('/'), true);
                };
                list.appendChild(parent);
            }

            res.files.forEach(f => {
                const item = document.createElement('div');
                item.className = 'file-item' + (f.type === 'directory' ? ' directory' : '');

                if (f.type === 'directory') {
                    item.innerHTML = `<span class="file-name">📁 ${f.name}</span>`;
                    item.onclick = () => loadFiles(f.path, true);
                } else {
                    const checked = selectedFiles.includes(f.path) ? 'checked' : '';
                    item.innerHTML = `
                        <input type="checkbox" ${checked} onchange="toggleFile('${f.path}', this.checked)">
                        <span class="file-name">📄 ${f.name}</span>
                        <span class="file-format">${f.format || 'OTHER'}</span>
                        <span class="file-size">${formatSize(f.size)}</span>
                    `;
                }
                list.appendChild(item);
            });
        }

        function updateBreadcrumb() {
            const bc = document.getElementById('breadcrumb');
            const parts = currentPath.split('/').filter(Boolean);
            let html = '<span onclick="loadFiles(\\'/\\', true)">/ root</span>';
            let path = '';
            parts.forEach(p => {
                path += '/' + p;
                const pCopy = path;
                html += ` / <span onclick="loadFiles('${pCopy}', true)">${p}</span>`;
            });
            bc.innerHTML = html;
        }

        function updateQuickNav() {
            const nav = document.getElementById('quick-nav');
            nav.innerHTML = allowedRoots
                .filter(r => r !== '/tmp')
                .map(r => `<button class="btn" onclick="loadFiles('${r}', true)">${r.replace(/^\\//, '')}</button>`)
                .join('');
        }

        function toggleFile(path, checked) {
            if (checked && !selectedFiles.includes(path)) {
                selectedFiles.push(path);
            } else if (!checked) {
                selectedFiles = selectedFiles.filter(f => f !== path);
            }
            document.getElementById('selected-count').textContent = selectedFiles.length;
        }

        function addManualPath() {
            const input = document.getElementById('manual-path');
            const path = input.value.trim();
            if (path && !selectedFiles.includes(path)) {
                selectedFiles.push(path);
                document.getElementById('selected-count').textContent = selectedFiles.length;
                input.value = '';
            }
        }

        function formatSize(bytes) {
            if (!bytes) return '';
            if (bytes < 1024) return bytes + ' B';
            if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
            if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
            return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
        }

        async function uploadFiles() {
            if (selectedFiles.length === 0) {
                alert('Please select at least one file');
                return;
            }

            const project = document.getElementById('project').value;
            if (!project) {
                alert('Please select a project');
                return;
            }

            const results = document.getElementById('results');
            results.innerHTML = '<div class="card">Uploading...</div>';

            const res = await api('upload', 'POST', {
                files: selectedFiles,
                project_id: project,
                subject_id: document.getElementById('subject').value,
                session_id: document.getElementById('session').value,
                scan_id: document.getElementById('scan').value,
                resource_label: document.getElementById('resource').value,
                session_type: document.getElementById('modality').value,
                scan_type: document.getElementById('scantype').value,
                verify_upload: true
            });

            let html = '<div class="card"><h2>Upload Results</h2>';
            html += `<p>Total: ${res.summary.total} | Success: ${res.summary.success} | Failed: ${res.summary.failed}</p>`;
            res.results.forEach(r => {
                html += `<div class="result-item ${r.status}">${r.file}: ${r.status}${r.error ? ' - ' + r.error : ''}</div>`;
            });
            html += '</div>';
            results.innerHTML = html;

            if (res.success) {
                selectedFiles = [];
                document.getElementById('selected-count').textContent = '0';
                loadFiles(currentPath, true);
            }
        }
    </script>
</body>
</html>'''


def main():
    parser = argparse.ArgumentParser(description='XNAT Upload Server')
    parser.add_argument('--port', type=int, default=DEFAULT_PORT, help=f'Port to listen on (default: {DEFAULT_PORT})')
    args = parser.parse_args()

    server = HTTPServer(('0.0.0.0', args.port), XNATUploadHandler)
    print(f"XNAT Upload Server running on http://0.0.0.0:{args.port}")
    print("Press Ctrl+C to stop")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == '__main__':
    main()
