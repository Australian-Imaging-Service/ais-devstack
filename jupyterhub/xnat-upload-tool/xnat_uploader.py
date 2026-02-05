"""
XNAT Uploader Module
====================

Python backend for uploading medical imaging data (DICOM, NIfTI) to XNAT.

This module provides functions for:
- Authenticating with XNAT using Alias Tokens (secure, user-specific)
- Checking user permissions on XNAT projects
- Uploading DICOM files to XNAT prearchive
- Uploading NIfTI and other files directly to archive at any hierarchy level
- Validating metadata and file formats

Authentication:
    Uses XNAT Alias Tokens for secure authentication via xnatpy library.
    Users generate their own alias/secret pair in XNAT UI (Profile → Alias Tokens → Create).
    This ensures:
    - No admin credentials exposed to users
    - Each action logged under the user's account
    - Tokens can be revoked individually
    - Single session reuse (no session leaks)

Author: Australian Imaging Service
Version: 3.2.0 (Auto File Format Detection)
"""

import os
import xnat
from pathlib import Path
from typing import List, Dict, Optional, Union, Tuple
from datetime import datetime
import zipfile
import tempfile
from contextlib import contextmanager
from urllib.parse import quote

# Try to import fileformats library for better file type detection
try:
    from fileformats.core import find_matching
    from fileformats.medimage import NiftiGz, NiftiGzX, Nifti1, NiftiX
    from fileformats.medimage import DicomDir, DicomSeries
    FILEFORMATS_AVAILABLE = True
except ImportError:
    FILEFORMATS_AVAILABLE = False


class XNATUploadError(Exception):
    """Custom exception for XNAT upload errors"""
    pass


class XNATUploader:
    """
    Main class for handling XNAT uploads from JupyterHub

    Uses xnatpy library for all XNAT interactions, ensuring proper session
    management and avoiding session leaks. Uses XNAT Alias Tokens for
    authentication instead of admin credentials.
    """

    # Map file extensions to XNAT format types for auto-detection
    FILE_FORMAT_MAP = {
        '.nii': 'NIFTI',
        '.nii.gz': 'NIFTI',
        '.dcm': 'DICOM',
        '.dicom': 'DICOM',
        '.csv': 'CSV',
        '.tsv': 'TSV',
        '.txt': 'TEXT',
        '.log': 'TEXT',
        '.json': 'JSON',
        '.xml': 'XML',
        '.png': 'PNG',
        '.jpg': 'JPEG',
        '.jpeg': 'JPEG',
        '.gif': 'GIF',
        '.tif': 'TIFF',
        '.tiff': 'TIFF',
        '.bmp': 'BMP',
        '.pdf': 'PDF',
        '.zip': 'ZIP',
        '.tar': 'TAR',
        '.gz': 'GZIP',
        '.mat': 'MATLAB',
        '.py': 'PYTHON',
        '.r': 'R',
        '.html': 'HTML',
        '.md': 'MARKDOWN',
    }

    # Map session types to scan types and xnatpy class names
    SESSION_TYPE_MAP = {
        'xnat:mrSessionData': {'scan_type': 'xnat:mrScanData', 'class': 'MrSessionData'},
        'xnat:ctSessionData': {'scan_type': 'xnat:ctScanData', 'class': 'CtSessionData'},
        'xnat:petSessionData': {'scan_type': 'xnat:petScanData', 'class': 'PetSessionData'},
        'xnat:petmrSessionData': {'scan_type': 'xnat:petmrScanData', 'class': 'PetmrSessionData'},
        'xnat:crSessionData': {'scan_type': 'xnat:crScanData', 'class': 'CrSessionData'},
    }

    def __init__(self, xnat_url: str = None):
        """
        Initialize XNAT Uploader

        Args:
            xnat_url: XNAT server URL (defaults to in-cluster service)
        """
        # Default to in-cluster XNAT service
        self.xnat_url = xnat_url or os.environ.get(
            'XNAT_URL',
            'http://xnat-web.ais-xnat.svc.cluster.local'
        )

        # Alias token credentials (user must set these)
        self._alias = None
        self._secret = None

        # Authenticated username (set after validation)
        self.authenticated_user = None

        # Cached xnatpy session (reused to avoid session leaks)
        self._session = None

    def set_credentials(self, alias: str, secret: str) -> None:
        """
        Set XNAT alias token credentials

        Args:
            alias: XNAT alias token
            secret: XNAT secret token
        """
        # If credentials change, close existing session
        if self._session is not None and (self._alias != alias or self._secret != secret):
            self._close_session()

        self._alias = alias
        self._secret = secret

    def _get_auth(self) -> Tuple[str, str]:
        """
        Get authentication tuple

        Returns:
            Tuple of (alias, secret)

        Raises:
            XNATUploadError: If credentials not set
        """
        if not self._alias or not self._secret:
            raise XNATUploadError(
                "XNAT credentials not configured. "
                "Please call set_credentials(alias, secret) first, or use the notebook form to enter your alias token."
            )
        return (self._alias, self._secret)

    def _get_session(self):
        """
        Get or create xnatpy session (reuses existing session)

        Returns:
            xnatpy session object

        Raises:
            XNATUploadError: If connection fails
        """
        if self._session is not None:
            try:
                # Test if session is still valid by making a simple request
                _ = self._session.JSESSION
                return self._session
            except Exception:
                # Session expired or invalid, close and recreate
                self._close_session()

        alias, secret = self._get_auth()

        try:
            self._session = xnat.connect(
                self.xnat_url,
                user=alias,
                password=secret
            )
            return self._session
        except Exception as e:
            raise XNATUploadError(f"Failed to connect to XNAT: {str(e)}")

    def _close_session(self) -> None:
        """Close the current xnatpy session if open"""
        if self._session is not None:
            try:
                self._session.disconnect()
            except Exception:
                pass  # Ignore errors during disconnect
            self._session = None

    @contextmanager
    def _session_context(self):
        """
        Context manager for xnatpy session

        Reuses existing session if available, otherwise creates new one.
        Does not close session on exit (for reuse).
        """
        session = self._get_session()
        try:
            yield session
        except Exception:
            # On error, close session to force reconnect next time
            self._close_session()
            raise

    def disconnect(self) -> None:
        """
        Explicitly disconnect from XNAT

        Call this when done with all operations to clean up the session.
        """
        self._close_session()
        self.authenticated_user = None

    def __del__(self):
        """Cleanup on object destruction"""
        self._close_session()

    @classmethod
    def detect_file_format(cls, file_path: Union[str, Path]) -> str:
        """
        Auto-detect file format from file extension and magic numbers.

        Uses the fileformats library if available for more accurate detection,
        falling back to extension-based detection.

        Args:
            file_path: Path to the file

        Returns:
            XNAT format type string (e.g., 'NIFTI', 'DICOM', 'CSV', 'OTHER')
        """
        path = Path(file_path)
        name = path.name.lower()

        # Try fileformats library first for better detection
        if FILEFORMATS_AVAILABLE and path.exists() and path.is_file():
            try:
                matches = list(find_matching(path))
                if matches:
                    # Get the most specific match
                    match_name = type(matches[0]).__name__.lower()

                    # Map fileformats class names to XNAT format types
                    if 'nifti' in match_name:
                        return 'NIFTI'
                    elif 'dicom' in match_name:
                        return 'DICOM'
                    elif 'analyze' in match_name:
                        return 'ANALYZE'
                    elif 'minc' in match_name:
                        return 'MINC'
                    elif 'mgh' in match_name or 'mgz' in match_name:
                        return 'MGH'
                    elif 'nrrd' in match_name:
                        return 'NRRD'
                    elif 'gifti' in match_name:
                        return 'GIFTI'
                    # Add more mappings as needed
            except Exception:
                pass  # Fall back to extension-based detection

        # Extension-based fallback detection

        # Handle special case: .nii.gz (compound extension)
        if name.endswith('.nii.gz'):
            return 'NIFTI'

        # Handle special case: .tar.gz
        if name.endswith('.tar.gz'):
            return 'TAR'

        # Get the suffix and look up in map
        suffix = path.suffix.lower()
        return cls.FILE_FORMAT_MAP.get(suffix, 'OTHER')

    def validate_credentials(self) -> Dict:
        """
        Validate alias token credentials with XNAT

        Returns:
            Dictionary with validation result:
            {
                'valid': bool,
                'username': str (if valid),
                'error': str (if invalid)
            }
        """
        try:
            self._get_auth()
        except XNATUploadError as e:
            return {'valid': False, 'username': None, 'error': str(e)}

        try:
            with self._session_context() as session:
                # xnatpy provides logged_in_user property
                username = session.logged_in_user

                if username:
                    self.authenticated_user = username
                    return {
                        'valid': True,
                        'username': username,
                        'error': None
                    }
                else:
                    # Fallback: try to get from profile endpoint using xnatpy's get_json
                    try:
                        profile_data = session.get_json('/xapi/users/profile')
                        username = profile_data.get('username', 'authenticated')
                        self.authenticated_user = username
                        return {
                            'valid': True,
                            'username': username,
                            'error': None
                        }
                    except Exception:
                        pass

                    self.authenticated_user = 'authenticated'
                    return {
                        'valid': True,
                        'username': 'authenticated',
                        'error': None
                    }

        except XNATUploadError as e:
            return {
                'valid': False,
                'username': None,
                'error': str(e)
            }
        except Exception as e:
            return {
                'valid': False,
                'username': None,
                'error': f'Connection error: {str(e)}'
            }

    def get_accessible_projects(self, writable_only: bool = True) -> List[Dict]:
        """
        Get list of projects the authenticated user can access

        Uses xnatpy's session.projects which returns an XNATListing

        Args:
            writable_only: If True, only return projects where user can upload (Owners/Members/Collaborators)

        Returns:
            List of project dictionaries with ID, name, description, and user's role
        """
        try:
            with self._session_context() as session:
                projects = []
                # session.projects is an XNATListing - iterate using .values()
                for project in session.projects.values():
                    project_id = project.id if hasattr(project, 'id') else str(project)

                    # Get user's role in this project
                    role = self._get_user_role_in_project(session, project_id)

                    # Skip projects where user only has read access if writable_only is True
                    if writable_only and role not in ['Owners', 'Members', 'Collaborators']:
                        continue

                    projects.append({
                        'id': project_id,
                        'name': project.name if hasattr(project, 'name') else project_id,
                        'description': project.description if hasattr(project, 'description') else '',
                        'role': role
                    })
                return projects
        except XNATUploadError:
            raise
        except Exception as e:
            raise XNATUploadError(f"Failed to fetch projects: {str(e)}")

    def _get_user_role_in_project(self, session, project_id: str) -> Optional[str]:
        """Get the current user's role in a project using xnatpy"""
        try:
            username = session.logged_in_user or self.authenticated_user
            if not username:
                return None

            # Use xnatpy's get_json for cleaner JSON response handling
            data = session.get_json(f'/data/projects/{project_id}/users/{username}')
            results = data.get('ResultSet', {}).get('Result', [])

            for result in results:
                if result.get('login') == username:
                    return result.get('displayname')
            return None
        except Exception:
            return None

    def check_permissions(self, project_id: str) -> Dict:
        """
        Check if authenticated user has write/upload permissions to a project

        Args:
            project_id: XNAT project ID

        Returns:
            Dictionary with permission details:
            {
                'has_permission': bool,
                'role': str (Owner/Member/Collaborator),
                'username': str
            }

        Raises:
            XNATUploadError: If permission check fails
        """
        try:
            with self._session_context() as session:
                username = session.logged_in_user or self.authenticated_user

                if not username:
                    raise XNATUploadError("Could not determine username from credentials")

                # Use xnatpy's projects listing to check access
                if project_id not in session.projects:
                    return {
                        'has_permission': False,
                        'role': None,
                        'username': username,
                        'error': f'Project {project_id} not found or not accessible'
                    }

                # Get user's role
                role = self._get_user_role_in_project(session, project_id)

                if role is None:
                    return {
                        'has_permission': False,
                        'role': None,
                        'username': username,
                        'error': f'User {username} not found in project {project_id}'
                    }

                has_permission = role in ['Owners', 'Members', 'Collaborators']

                return {
                    'has_permission': has_permission,
                    'role': role,
                    'username': username
                }

        except XNATUploadError:
            raise
        except Exception as e:
            raise XNATUploadError(f"Permission check failed: {str(e)}")

    def _get_or_create_subject(self, session, project, subject_id: str):
        """Get existing subject or create new one using xnatpy object model"""
        if subject_id in project.subjects:
            return project.subjects[subject_id]

        # Create subject using xnatpy's classes
        return session.classes.SubjectData(parent=project, label=subject_id)

    def _get_or_create_experiment(self, session, subject, experiment_id: str,
                                   session_type: str = 'xnat:mrSessionData'):
        """Get existing experiment or create new one using xnatpy object model"""
        if experiment_id in subject.experiments:
            existing = subject.experiments[experiment_id]
            # Check type compatibility
            existing_type = existing.xsi_type if hasattr(existing, 'xsi_type') else None
            if existing_type and existing_type != session_type:
                raise XNATUploadError(
                    f"Session {experiment_id} already exists with type '{existing_type}', "
                    f"but you're trying to upload with type '{session_type}'. "
                    f"Either use a different session ID or change the modality."
                )
            return existing

        # Get the appropriate class from xnatpy
        type_info = self.SESSION_TYPE_MAP.get(session_type, {})
        class_name = type_info.get('class', 'MrSessionData')

        if hasattr(session.classes, class_name):
            session_class = getattr(session.classes, class_name)
            return session_class(parent=subject, label=experiment_id)
        else:
            # Fallback: create via REST
            project_id = subject.project if hasattr(subject, 'project') else subject.parent.id
            subject_id = subject.label if hasattr(subject, 'label') else str(subject)
            uri = f'/data/projects/{project_id}/subjects/{subject_id}/experiments/{experiment_id}'
            response = session.put(uri, query={'xsiType': session_type})
            if response.status_code not in [200, 201]:
                raise XNATUploadError(f"Failed to create session: {response.status_code}")
            # Refresh and return
            return subject.experiments[experiment_id]

    def _get_or_create_scan(self, session, experiment, scan_id: str,
                            scan_type: str = 'xnat:mrScanData',
                            scan_label: str = 'OTHER'):
        """Get existing scan or create new one"""
        if scan_id in experiment.scans:
            return experiment.scans[scan_id]

        # Create scan via REST (xnatpy doesn't have direct scan creation classes)
        uri = experiment.uri + f'/scans/{scan_id}'
        response = session.put(uri, query={'xsiType': scan_type, 'type': scan_label})

        if response.status_code not in [200, 201]:
            raise XNATUploadError(f"Failed to create scan {scan_id}: {response.status_code}")

        # Refresh experiment and return scan
        experiment.clearcache()
        return experiment.scans[scan_id]

    def _get_or_create_resource(self, parent_obj, resource_label: str,
                                 file_format: str = None, file_content: str = None):
        """
        Get or create a resource on any XNAT object (project, subject, experiment, scan)

        Uses xnatpy's resource handling
        """
        # Check if resource exists
        if resource_label in parent_obj.resources:
            return parent_obj.resources[resource_label]

        # Create resource - xnatpy resources are created implicitly on first file upload
        # But we can also create them explicitly via REST
        uri = parent_obj.uri + f'/resources/{resource_label}'

        query = {}
        if file_format:
            query['format'] = file_format
        if file_content:
            query['content'] = file_content

        # Note: resource is created when we upload the file
        return resource_label  # Return the label, actual resource created on upload

    def _get_hierarchy_description(
        self,
        project_id: str,
        subject_id: Optional[str] = None,
        session_id: Optional[str] = None,
        scan_id: Optional[str] = None
    ) -> str:
        """Get human-readable description of upload location"""
        if scan_id and session_id and subject_id:
            return f"Project {project_id} > Subject {subject_id} > Session {session_id} > Scan {scan_id} > Resources"
        elif session_id and subject_id:
            return f"Project {project_id} > Subject {subject_id} > Session {session_id} > Resources"
        elif subject_id:
            return f"Project {project_id} > Subject {subject_id} > Resources"
        else:
            return f"Project {project_id} > Resources"

    def _upload_to_resource(self, session, parent_obj, resource_label: str,
                            file_path: Path, file_format: str = None,
                            file_content: str = None, tags: str = None) -> Dict:
        """
        Upload file to a resource using xnatpy's upload mechanism

        Args:
            session: xnatpy session
            parent_obj: Parent object (project, subject, experiment, or scan)
            resource_label: Resource label (e.g., 'NIFTI', 'FILES')
            file_path: Path to local file
            file_format: Optional format metadata
            file_content: Optional content type metadata
            tags: Optional tags

        Returns:
            Dictionary with upload result
        """
        filename = file_path.name

        # Build the upload URI
        # xnatpy's upload method: session.upload(uri, file_path)
        resource_uri = f"{parent_obj.uri}/resources/{resource_label}/files/{quote(filename)}"

        # Build query parameters
        query_parts = []
        if file_format:
            query_parts.append(f"format={quote(file_format)}")
        if file_content:
            query_parts.append(f"content={quote(file_content)}")
        if tags:
            query_parts.append(f"tags={quote(tags)}")

        if query_parts:
            upload_uri = resource_uri + "?" + "&".join(query_parts)
        else:
            upload_uri = resource_uri

        # Use xnatpy's upload_file method (avoids deprecation warning)
        session.upload_file(upload_uri, str(file_path))

        return {
            'uri': resource_uri,
            'filename': filename,
            'size': file_path.stat().st_size
        }

    def _verify_file_exists(self, session, parent_obj, resource_label: str,
                            filename: str) -> Dict:
        """
        Verify that a file exists in a resource using xnatpy

        Returns:
            Dictionary with verification details
        """
        try:
            # Try to access the resource and check for the file
            if resource_label in parent_obj.resources:
                resource = parent_obj.resources[resource_label]
                # xnatpy resources have a files property
                if hasattr(resource, 'files') and filename in resource.files:
                    file_obj = resource.files[filename]
                    return {
                        'exists': True,
                        'size': file_obj.size if hasattr(file_obj, 'size') else None,
                        'uri': file_obj.uri if hasattr(file_obj, 'uri') else None
                    }

            # Fallback: check via REST
            uri = f"{parent_obj.uri}/resources/{resource_label}/files/{quote(filename)}"
            response = session.head(uri)

            return {
                'exists': response.status_code == 200,
                'status_code': response.status_code,
                'uri': uri
            }

        except Exception as e:
            return {
                'exists': False,
                'error': str(e)
            }

    def upload_file(
        self,
        file_path: Union[str, Path],
        project_id: str,
        subject_id: Optional[str] = None,
        session_id: Optional[str] = None,
        scan_id: Optional[str] = None,
        resource_label: str = 'FILES',
        file_format: str = 'NIFTI',
        file_content: str = 'RAW',
        tags: Optional[str] = None,
        auto_create: bool = True,
        session_type: str = 'xnat:mrSessionData',
        scan_modality: Optional[str] = None,
        scan_type: str = 'OTHER',
        verify_upload: bool = True
    ) -> Dict:
        """
        Upload file to XNAT archive at the appropriate hierarchy level

        Uses xnatpy's object model to navigate and upload files.

        The upload location is determined by which parameters are provided:
        - Project only: uploads to project/resources/
        - Project + Subject: uploads to project/subject/resources/
        - Project + Subject + Session: uploads to project/subject/session/resources/
        - Project + Subject + Session + Scan: uploads to project/subject/session/scan/resources/

        Args:
            file_path: Path to file to upload
            project_id: Target XNAT project ID (required)
            subject_id: Subject ID (optional - if not provided, uploads to project level)
            session_id: Session/Experiment ID (optional - requires subject_id)
            scan_id: Scan ID (optional - requires session_id)
            resource_label: Resource label (default: 'FILES')
            file_format: File format (e.g., 'NIFTI', 'ANALYZE')
            file_content: Content type (e.g., 'RAW', 'PROCESSED')
            tags: Optional tags (comma-separated)
            auto_create: If True, automatically create subject/session/scan if not exists
            session_type: XNAT session type for auto-creation (default: xnat:mrSessionData)
            scan_modality: XNAT scan modality (default: auto-inferred from session_type)
            scan_type: Scan type label (default: OTHER)
            verify_upload: If True, verify file exists in XNAT after upload

        Returns:
            Dictionary with upload result

        Raises:
            XNATUploadError: If upload fails or verification fails
        """
        file_path = Path(file_path)
        if not file_path.exists():
            raise XNATUploadError(f"File not found: {file_path}")

        # Validate hierarchy logic
        if scan_id and not session_id:
            raise XNATUploadError("scan_id requires session_id to be provided")
        if session_id and not subject_id:
            raise XNATUploadError("session_id requires subject_id to be provided")

        try:
            with self._session_context() as session:
                # Navigate to the correct parent object using xnatpy's object model
                project = session.projects[project_id]
                parent_obj = project  # Default to project level

                if subject_id:
                    if auto_create:
                        subject = self._get_or_create_subject(session, project, subject_id)
                    else:
                        subject = project.subjects[subject_id]
                    parent_obj = subject

                    if session_id:
                        if auto_create:
                            experiment = self._get_or_create_experiment(
                                session, subject, session_id, session_type
                            )
                        else:
                            experiment = subject.experiments[session_id]
                        parent_obj = experiment

                        if scan_id:
                            if scan_modality is None:
                                type_info = self.SESSION_TYPE_MAP.get(session_type, {})
                                scan_modality = type_info.get('scan_type', 'xnat:mrScanData')

                            if auto_create:
                                scan = self._get_or_create_scan(
                                    session, experiment, scan_id,
                                    scan_modality, scan_type
                                )
                            else:
                                scan = experiment.scans[scan_id]
                            parent_obj = scan

                # Upload the file
                filename = file_path.name
                file_size = file_path.stat().st_size

                upload_result = self._upload_to_resource(
                    session, parent_obj, resource_label, file_path,
                    file_format, file_content, tags or 'uploaded_from_jupyterhub'
                )

                result = {
                    'success': True,
                    'message': f'File {filename} uploaded successfully',
                    'file_uri': upload_result.get('uri'),
                    'location': self._get_hierarchy_description(
                        project_id, subject_id, session_id, scan_id
                    ),
                    'file_size': file_size,
                    'verified': False
                }

                # Verify the upload if requested
                if verify_upload:
                    # Clear cache to get fresh data
                    if hasattr(parent_obj, 'clearcache'):
                        parent_obj.clearcache()

                    verify_result = self._verify_file_exists(
                        session, parent_obj, resource_label, filename
                    )

                    if not verify_result.get('exists'):
                        raise XNATUploadError(
                            f"Upload reported success but file verification failed. "
                            f"The file '{filename}' was not found at: {result['location']}"
                        )

                    result['verified'] = True
                    result['verification_details'] = verify_result

                return result

        except XNATUploadError:
            raise
        except KeyError as e:
            raise XNATUploadError(f"Object not found: {str(e)}")
        except Exception as e:
            raise XNATUploadError(f"Upload error: {str(e)}")

    def upload_dicom_to_prearchive(
        self,
        dicom_files: List[Union[str, Path]],
        project_id: str,
        subject_id: str,
        session_id: str,
        overwrite: str = 'none'
    ) -> Dict:
        """
        Upload DICOM files to XNAT prearchive (staging area)

        Uses xnatpy's import service: session.services.import_()

        Args:
            dicom_files: List of paths to DICOM files
            project_id: Target XNAT project ID
            subject_id: Subject ID
            session_id: Session/Experiment ID
            overwrite: Overwrite strategy ('none', 'append', 'delete')

        Returns:
            Dictionary with upload result including prearchive session ID

        Raises:
            XNATUploadError: If upload fails
        """
        # Validate files exist
        for file_path in dicom_files:
            if not Path(file_path).exists():
                raise XNATUploadError(f"File not found: {file_path}")

        with tempfile.NamedTemporaryFile(suffix='.zip', delete=False) as tmp_zip:
            zip_path = tmp_zip.name

            try:
                # Create zip archive of DICOM files
                with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
                    for file_path in dicom_files:
                        zipf.write(file_path, arcname=Path(file_path).name)

                with self._session_context() as session:
                    # Use xnatpy's import service (official method)
                    prearchive_session = session.services.import_(
                        zip_path,
                        project=project_id,
                        subject=subject_id,
                        experiment=session_id,
                        overwrite=overwrite,
                        destination='/prearchive'
                    )

                    return {
                        'success': True,
                        'message': 'DICOM files uploaded to prearchive successfully',
                        'prearchive_session': str(prearchive_session) if prearchive_session else session_id,
                        'files_uploaded': len(dicom_files),
                        'project': project_id,
                        'subject': subject_id,
                        'session': session_id
                    }

            except XNATUploadError:
                raise
            except Exception as e:
                raise XNATUploadError(f"DICOM upload failed: {str(e)}")
            finally:
                if Path(zip_path).exists():
                    Path(zip_path).unlink()

    def get_prearchive_sessions(self, project_id: Optional[str] = None) -> List[Dict]:
        """
        Get list of sessions in the prearchive

        Uses xnatpy's prearchive API: session.prearchive.sessions()

        Args:
            project_id: Optional project ID to filter by

        Returns:
            List of prearchive session dictionaries
        """
        try:
            with self._session_context() as session:
                # Use xnatpy's prearchive.sessions() method
                prearchive_sessions = session.prearchive.sessions()

                result = []
                for pa_session in prearchive_sessions:
                    if project_id and pa_session.project != project_id:
                        continue

                    result.append({
                        'project': pa_session.project,
                        'subject': pa_session.subject if hasattr(pa_session, 'subject') else None,
                        'session': pa_session.name if hasattr(pa_session, 'name') else str(pa_session),
                        'status': pa_session.status if hasattr(pa_session, 'status') else None,
                        'timestamp': pa_session.timestamp if hasattr(pa_session, 'timestamp') else None
                    })

                return result

        except Exception as e:
            raise XNATUploadError(f"Failed to get prearchive sessions: {str(e)}")

    def verify_upload_comprehensive(
        self,
        project_id: str,
        resource_label: str,
        filename: str,
        subject_id: Optional[str] = None,
        session_id: Optional[str] = None,
        scan_id: Optional[str] = None,
        expected_size: Optional[int] = None
    ) -> Dict:
        """
        Comprehensive verification of uploaded file

        Uses xnatpy object model to verify file existence and properties.

        Checks:
        - File exists in XNAT
        - File size matches (if expected_size provided)
        - File is accessible

        Args:
            project_id: XNAT project ID
            resource_label: Resource label
            filename: Uploaded filename
            subject_id: Subject ID (optional)
            session_id: Session ID (optional)
            scan_id: Scan ID (optional)
            expected_size: Expected file size in bytes (optional)

        Returns:
            Dictionary with comprehensive verification results
        """
        try:
            with self._session_context() as session:
                result = {
                    'file_exists': False,
                    'size_match': None,
                    'accessible': False,
                    'details': {}
                }

                # Navigate to parent object
                project = session.projects[project_id]
                parent_obj = project

                if subject_id:
                    parent_obj = project.subjects[subject_id]
                    if session_id:
                        parent_obj = parent_obj.experiments[session_id]
                        if scan_id:
                            parent_obj = parent_obj.scans[scan_id]

                # Check file using xnatpy resource/files
                verify_result = self._verify_file_exists(
                    session, parent_obj, resource_label, filename
                )

                result['file_exists'] = verify_result.get('exists', False)
                result['details']['uri'] = verify_result.get('uri')

                if not result['file_exists']:
                    result['error'] = 'File not found in XNAT'
                    return result

                # Size verification
                if verify_result.get('size') is not None and expected_size is not None:
                    actual_size = int(verify_result['size'])
                    result['size_match'] = actual_size == expected_size
                    result['details']['actual_size'] = actual_size
                    result['details']['expected_size'] = expected_size

                result['accessible'] = result['file_exists']
                result['verified'] = (
                    result['file_exists'] and
                    (result['size_match'] is None or result['size_match'])
                )

                return result

        except Exception as e:
            return {
                'file_exists': False,
                'size_match': None,
                'accessible': False,
                'verified': False,
                'error': str(e)
            }

    def download_file(
        self,
        project_id: str,
        resource_label: str,
        filename: str,
        local_path: Union[str, Path],
        subject_id: Optional[str] = None,
        session_id: Optional[str] = None,
        scan_id: Optional[str] = None
    ) -> Dict:
        """
        Download a file from XNAT using xnatpy

        Uses xnatpy's download functionality.

        Args:
            project_id: XNAT project ID
            resource_label: Resource label
            filename: Remote filename
            local_path: Local path to save file
            subject_id: Subject ID (optional)
            session_id: Session ID (optional)
            scan_id: Scan ID (optional)

        Returns:
            Dictionary with download result
        """
        try:
            with self._session_context() as session:
                # Navigate to parent object
                project = session.projects[project_id]
                parent_obj = project

                if subject_id:
                    parent_obj = project.subjects[subject_id]
                    if session_id:
                        parent_obj = parent_obj.experiments[session_id]
                        if scan_id:
                            parent_obj = parent_obj.scans[scan_id]

                # Get resource and file
                resource = parent_obj.resources[resource_label]
                file_obj = resource.files[filename]

                # Download using xnatpy's download method
                file_obj.download(str(local_path))

                return {
                    'success': True,
                    'local_path': str(local_path),
                    'filename': filename
                }

        except KeyError as e:
            raise XNATUploadError(f"Object not found: {str(e)}")
        except Exception as e:
            raise XNATUploadError(f"Download failed: {str(e)}")

    def validate_dicom_files(self, file_paths: List[Union[str, Path]]) -> Dict:
        """Basic validation of DICOM files"""
        results = {'valid': True, 'files_checked': 0, 'errors': [], 'warnings': []}

        for file_path in file_paths:
            path = Path(file_path)
            results['files_checked'] += 1

            if not path.exists():
                results['valid'] = False
                results['errors'].append(f"File not found: {file_path}")
                continue

            size_mb = path.stat().st_size / (1024 * 1024)
            if size_mb > 500:
                results['warnings'].append(f"Large file {path.name} ({size_mb:.1f} MB)")

            try:
                with open(path, 'rb') as f:
                    header = f.read(132)
                    if len(header) >= 132 and header[128:132] != b'DICM':
                        results['warnings'].append(
                            f"{path.name} may not be a valid DICOM file (missing DICM marker)"
                        )
            except Exception as e:
                results['valid'] = False
                results['errors'].append(f"Cannot read {path.name}: {str(e)}")

        return results

    def get_session_info(self) -> Dict:
        """
        Get information about the current XNAT session

        Returns:
            Dictionary with session information
        """
        try:
            with self._session_context() as session:
                return {
                    'connected': True,
                    'server': self.xnat_url,
                    'user': session.logged_in_user or self.authenticated_user,
                    'jsession': session.JSESSION if hasattr(session, 'JSESSION') else None
                }
        except Exception as e:
            return {
                'connected': False,
                'server': self.xnat_url,
                'user': self.authenticated_user,
                'error': str(e)
            }
