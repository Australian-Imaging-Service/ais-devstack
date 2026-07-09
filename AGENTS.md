# AIS-XNAT Deployment for k3s

XNAT deployment on k3s with node-local storage for the Australian Imaging Service.

### Important guidelines:

- Never write credentials directly into the codebase and never commit them to github. Always use SOPS to encrypt secrets.
- Always test if you changes actually worked on the cluster
- Always check AGENTS.md file if the changes made should be documented in there.
- Always make sure there is local account admin and that it's not possible to login with local user accounts. The admin password is stored in the `xnat-archiver-creds` Kubernetes secret.

### Deployment Notes

- `kubectl` requires `sudo` on this machine (k3s kubeconfig at `/etc/rancher/k3s/k3s.yaml` is root-only)
- XNAT runs as a StatefulSet (`xnat-web-0`), rollouts take a few minutes for the pod to terminate and restart
- Always use `--post-renderer ./manifests/kustomize.sh` with helm commands — it applies XNAT storage volume mount patches
- After helm upgrade, verify with: `sudo kubectl -n ais-xnat rollout status statefulset/xnat-web`
- XNAT archive storage uses static `local` PVs pinned to `xnat-host` under `/srv/xnat-local-storage`. The in-cluster NFS server is legacy only and should not be in XNAT/Jupyter's write path.
- Project archive directories must be explicitly mounted in `manifests/kustomization.yaml` and mirrored in `jupyterhub/2-xnat-mount-mapping.yaml`. If an existing project has data in the pod-local `/data/xnat/archive/<project>` path, copy it to `/srv/xnat-local-storage/gpfs/archive/<project>` before adding the mount, otherwise the rollout will hide or lose that local-only data.
- JupyterHub XNAT launches keep the Jupyter file-browser root at `/home/jovyan`. XNAT data mounts remain available at their original `/data/...` targets and are also mirrored under `/home/jovyan/xnat-data/...`; JupyterLab opens in the mirrored XNAT data target, or `/home/jovyan` when no XNAT data is mounted.
- JupyterHub allows two XNAT named servers per user. Keep `cull.removeNamedServers: true` enabled so stopped timestamped servers are removed instead of blocking new launches.
- XNAT Container Service uses the host Docker daemon through `/var/run/docker.sock`, mounted by `manifests/kustomization.yaml`. Docker runs containers on the host, so host paths must match XNAT's visible paths. Keep the host-side `/data/xnat` symlink mirror in sync with XNAT archive/build mounts, especially when adding new project archive mounts.
- `manifests/gcs-fuse-mount.yaml` runs `xnat-gcs-fuse`, which mounts `gs://xnat-lucas-archive` read-only at `/srv/xnat-local-storage/gpfs/object-store` and exposes it in XNAT/Jupyter as `/data/xnat/object-store`. Keep the host mirror symlink `/data/xnat/object-store -> /srv/xnat-local-storage/gpfs/object-store` in place for Container Service host-Docker jobs. The archiver may replace verified local archive files with symlinks into `/data/xnat/object-store/sessions/<project>/<session>/...`; keep catalog/session XML files local and verify the FUSE mount before enabling bulk offload.
- XNAT Container Service pipelines are stored in `container-service/commands/` and installed via `scripts/install-mriqc-container-service.sh`. The bundle includes `xnat/dcm2bids-session:1.5.1` for DICOM-to-NIFTI/BIDS resources and `nipreps/mriqc:24.0.2` through `xnat2bids`; MRIQC sessions must already have scan-level `NIFTI` resources and `BIDS` JSON sidecars. DICOM-to-BIDS depends on a site or project BIDS map at `/data/config/bids/bidsmap` or `/data/projects/<project>/config/bids/bidsmap`. The installer enables wrappers site-wide and for existing projects; `manifests/container-service-project-sync.yaml` keeps wrappers enabled for future projects.
- `manifests/project-owner-sync.yaml` keeps `brosnan` in the XNAT `Owners` group for every current and future project. It runs every 15 minutes using the admin credentials from `xnat-archiver-creds`; apply it with `sudo kubectl apply -f manifests/project-owner-sync.yaml` and trigger a manual job after changes to verify.
- The site-wide BIDS map lives at `container-service/bidsmap/site-bidsmap.json` and is installed with `scripts/install-bidsmap.sh`. XNAT's dcm2bids map uses exact, case-insensitive `series_description` matches; avoid adding broad or guessed mappings for scouts, B1 maps, reports, ADC/TRACEW derivatives, or project-specific task names without checking the project protocol.
- OHIF viewer 3.7.2 is hotfixed in `manifests/configmap.yaml` during XNAT pod init so server-side metadata generation scans only `DICOM`/`secondary` resource paths, preserves original DICOM filenames in generated URLs, skips common raw/data extensions such as `.dat`, and skips files larger than 1 GiB by default (`OHIF_METADATA_MAX_SCAN_BYTES` can override). This prevents large raw data files in scan resources from being parsed as DICOM and OOMing Tomcat.

### Verify Installation

```bash
# Watch pods start up
sudo kubectl -n ais-xnat get pods -w

# Port forward to access locally
sudo kubectl -n ais-xnat port-forward svc/xnat-web 8080:80
```


## Configuration

### Ingress Host

Edit `manifests/values.yaml` to change the ingress hostname:

```yaml
xnat-web:
  ingress:
    hosts:
      - host: your-domain.example.com
```


#### Apply Configuration Changes

After updating the configuration files:

```bash
# Upgrade XNAT
helm upgrade xnat-web ais/xnat \
  --namespace ais-xnat \
  --values manifests/values.yaml \
  --post-renderer ./manifests/kustomize.sh

# Upgrade JupyterHub
helm upgrade jupyterhub jupyterhub/jupyterhub -n jupyter \
  --values jupyterhub/5-jupyterhub-values.yaml
```


## Stanford OIDC Authentication

XNAT uses the `openid-auth-plugin` with Stanford's Shibboleth-based OIDC provider (`login.stanford.edu`).

### Key OIDC endpoints (Stanford)

- Authorization: `https://login.stanford.edu/idp/profile/oidc/authorize`
- Token: `https://login.stanford.edu/idp/profile/oidc/token`
- UserInfo: `https://login.stanford.edu/idp/profile/oidc/userinfo`

### Critical: `userInfoUri` is required

Stanford's Shibboleth IdP puts minimal claims in the ID token (typically just `sub`). The `userInfoUri` must be configured so the XNAT plugin fetches the full profile (name, email, SUNet ID) from the UserInfo endpoint. Without it, user attributes won't be populated even though the consent screen asks for permission to share them.

### Claim mapping

The XNAT plugin maps OIDC claims to user fields via these properties in `values.yaml`:
- `usernamePattern` — which claim becomes the XNAT username. Use `[email_prefix]` (custom patch) which extracts the part before `@` from the email claim (e.g., `sciget` from `sciget@stanford.edu`). Do NOT use `[sub]` — Stanford's `sub` is a UUID with `@stanford.edu` suffix that fails XNAT's `sanitizeUsername`. Do NOT use `[preferred_username]` — although Stanford returns it in the UserInfo response, it is not listed in their OIDC discovery endpoint's `claims_supported` and was unreliable in testing. The `[email_prefix]` token is a custom patch in `plugins/patches/OpenIdConnectUserDetails.java`.
- `emailProperty` — claim name for email (standard: `email`)
- `givenNameProperty` — claim name for first name (standard: `given_name`)
- `familyNameProperty` — claim name for last name (standard: `family_name`)

If user attributes still don't arrive after adding `userInfoUri`, debug by calling the UserInfo endpoint directly with an access token to see the exact claim names Stanford returns — Shibboleth IdPs sometimes use non-standard names.

### Stanford RP configuration

The Stanford relying party is managed at Stanford's RP Manager. Key settings:
- Client ID: configured in `values.yaml` under `openid.stanford.clientId`
- Scopes must include: `openid`, `profile`, `email`
- Subject Type: `public`
- PKCE: enabled (matches `pkceEnabled: true` in values.yaml)
- Redirect URIs must include: `https://<domain>/openid-login`

## ais-edge ingestion → service account & projects

The [ais-edge](https://github.com/Australian-Imaging-Service/ais-edge) management node uploads de-identified DICOMs into this XNAT via REST. It needs a **localdb** service account because the `xnat-ingest-upload` pod authenticates with `POST /data/JSESSION` + username/password (Stanford OIDC is interactive-only).

### One-shot setup / disaster recovery

```bash
./scripts/setup-edge-uploader.sh
```

Idempotent. Creates the user, grants `Administrator` role, creates the seed projects, makes the user an Owner of each, and stores credentials in the `edge-uploader-creds` k8s secret. Re-running against existing state is a no-op for the password. Env overrides: `XNAT_URL`, `EDGE_USER`, `EDGE_EMAIL`, `EDGE_PROJECTS`, `XNAT_NAMESPACE`.

### What it provisions

- **Service account**: `edge-uploader` (localdb), email `mail.neurodesk@gmail.com`, site-wide `Administrator` role
- **Seed projects** (Owner = `edge-uploader`): `polimeni`, `ennis`, `dicomtest`, `misc` (catch-all for un-routed AETs), `Siemens_cimax`
- **k8s secret** `ais-xnat/edge-uploader-creds` with keys `username`, `password`, `xnat_url`, `email`

### Why REST works despite OIDC-only login

`siteConfig.enabledProviders` is `["stanford"]` — the web login form refuses localdb. But REST `POST /data/JSESSION` and HTTP Basic on `/xapi/*` / `/data/*` still accept localdb credentials. So service accounts work without weakening the OIDC enforcement on humans.

### DICOM metadata pull workflow failures

If XNAT shows many failed `Pulled Data from DICOM` workflows after ais-edge uploads, check the `xnat-upload/xnat-ingest-upload` deployment. Catalog-only `DICOM` resources in the archive make XNAT's `pullDataFromHeaders=true` endpoint fail with `Unable to locate DICOM or ECAT files`; the ingest uploader should skip that header-pull step unless local DICOM objects are actually present. Active stale failures can be dismissed by marking `wrk_workflowdata.status` as `Failed (Dismissed)` for `pipeline_name='Pulled Data from DICOM'`.

The `xnat-ingest-upload` deployment also hot-patches `xnat-ingest` idempotency (`ais-devstack/empty-resource-hotfix=xnat-ingest-empty-resources-not-uploaded-v4`) so existing empty or partial XNAT resources do not count as uploaded. It compares staged resource manifest file names with XNAT catalog entries before skipping an upload. If an upload is interrupted and leaves truncated files outside the XNAT catalog, delete the partial XNAT experiment/resource with `removeFiles=true` and let the staged data re-upload; do not move the staged prefix to `uploaded/` until XNAT file counts match the staged file count.

The in-cluster `xnat-ingest-upload` deployment is also hot-patched with `ais-devstack/scan-uid-backfill=xnat-ingest-backfill-scan-uids-v3`. The hook runs before staged sessions are archived: it resolves staged session labels to `XNAT_E...` experiment IDs through the project/subject experiment listing (direct `/data/experiments/<label>/...` calls can return HTTP 500), waits until XNAT file counts match staged file counts, range-reads one DICOM header per scan, extracts top-level `SeriesInstanceUID`, and writes `xnat:mrScanData/UID` for blank scan UIDs. Keep equivalent behavior if the deployment is rebuilt; otherwise catalog-only uploads can archive successfully while leaving OHIF with zero instances.

For OHIF sessions that show studies/series but no instances, check `xnat_imagescandata.uid`: OHIF maps DICOM `SeriesInstanceUID` to XNAT scan IDs through that field. After restoring catalog-only sessions, regenerate OHIF metadata and verify instance counts; if instances remain zero, populate scan UIDs from the DICOM `SeriesInstanceUID` values and regenerate metadata. Catalog audits should check both zero `xnat_abstractresource.file_count` and nonzero file counts whose catalog XML is missing or has no `cat:entry` elements.

### GCS archiver failures

The `xnat-gcs-archiver` CronJob intentionally skips sessions with zero XNAT file records before backing up. Many historical session shells have no files and no `.backup_complete` marker; treating those as backup failures causes the nightly job to fail even though there is nothing to back up.

The archiver queries both scan-level files (`/scans/ALL/files`) and experiment-level resources (`/files`) to decide whether a session has data, then backs up from the local archive directory by default (`BACKUP_SOURCE_MODE=local`) instead of downloading ZIPs through XNAT REST. `BACKUP_SOURCE_MODE=rest` is retained as a rollback path. Experiment-level resources are required for sessions such as `openrecon/test-upload`, where the session has a top-level `FILES` resource but no scan files. With `OFFLOAD_AFTER_BACKUP=1`, the CronJob only replaces local files with symlinks after the object-store file is visible through the FUSE mount and has the same byte size. Keep catalog/session XML and ingestion logs such as `dcmtoxnat.log` local. Bulk historical offload jobs should also set `OFFLOAD_EXISTING_BACKUPS=1` and `REPAIR_INCOMPLETE_BACKUPS=1`; if a stale `.backup_complete` marker exists but local files have no matching object, the job removes that marker, re-syncs the session, and retries the offload.

### Credentials for ais-edge `config/management.env`

```bash
XNAT_URL=https://xnat-lucas.neurodesk.org
XNAT_USER=edge-uploader
XNAT_PASS=$(sudo kubectl -n ais-xnat get secret edge-uploader-creds -o jsonpath='{.data.password}' | base64 -d)
```

### Manual curl recipes (for reference / rotation)

Admin credentials come from the `xnat-archiver-creds` secret:

```bash
ADMIN_PW=$(sudo kubectl -n ais-xnat get secret xnat-archiver-creds -o jsonpath='{.data.password}' | base64 -d)
```

Create the user:

```bash
EDGE_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
curl -sS -u "admin:${ADMIN_PW}" -X POST https://xnat-lucas.neurodesk.org/xapi/users \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"edge-uploader\",\"password\":\"${EDGE_PW}\",\"email\":\"mail.neurodesk@gmail.com\",\"firstName\":\"Edge\",\"lastName\":\"Uploader\",\"enabled\":true,\"verified\":true}"
```

Grant site-wide Administrator role:

```bash
curl -sS -u "admin:${ADMIN_PW}" -X PUT \
  https://xnat-lucas.neurodesk.org/xapi/users/edge-uploader/roles/Administrator
```

Create a project and assign Owner:

```bash
PROJ=misc
curl -sS -u "admin:${ADMIN_PW}" -X PUT \
  "https://xnat-lucas.neurodesk.org/data/projects/${PROJ}?name=${PROJ}&secondary_ID=${PROJ}"
curl -sS -u "admin:${ADMIN_PW}" -X PUT \
  "https://xnat-lucas.neurodesk.org/data/projects/${PROJ}/users/Owners/edge-uploader"
```

Rotate the password (re-stores the secret):

```bash
NEW_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
curl -sS -u "admin:${ADMIN_PW}" -X PUT \
  "https://xnat-lucas.neurodesk.org/xapi/users/edge-uploader/password" \
  -H "Content-Type: text/plain" --data "$NEW_PW"
sudo kubectl -n ais-xnat delete secret edge-uploader-creds
sudo kubectl -n ais-xnat create secret generic edge-uploader-creds \
  --from-literal=username=edge-uploader \
  --from-literal=password="$NEW_PW" \
  --from-literal=xnat_url=https://xnat-lucas.neurodesk.org \
  --from-literal=email=mail.neurodesk@gmail.com
```

## Troubleshooting

### XNAT pod stuck in Init

```bash
kubectl -n ais-xnat describe pod xnat-web-0
kubectl -n ais-xnat logs xnat-web-0 -c home-init
```

### Local storage issues

```bash
# Check static local PV/PVC binding
kubectl get pv
kubectl -n ais-xnat get pvc
kubectl -n jupyter get pvc xnat-gpfs

# Check the node-local backing directory
sudo du -sh /srv/xnat-local-storage
findmnt /srv/xnat-local-storage
```

The old in-cluster NFS server exported `storage/pv-nfs-server`, a `local-path`
PVC on the node root disk. XNAT and Jupyter mounted that export back through NFS
from the same node, which could deadlock all `nfsd` workers during large uploads.
Do not reintroduce NFS for XNAT archive writes. If emergency recovery requires
temporarily starting the legacy server, keep write-heavy uploaders paused:

```bash
sudo kubectl -n storage exec deploy/nfs-server -- rpc.nfsd 32
sudo kubectl -n storage exec deploy/nfs-server -- cat /proc/fs/nfsd/threads
```

The current local PV paths still live on the boot persistent disk unless a
separate disk is mounted at `/srv/xnat-local-storage`. For sustained heavy
writes, prefer attaching and mounting a dedicated disk at that path.

### OIDC login issues

```bash
# Check XNAT logs for OIDC errors
sudo kubectl -n ais-xnat logs xnat-web-0 -c xnat-web | grep -i openid

# Debug claims returned by Stanford's UserInfo endpoint
curl -H "Authorization: Bearer <ACCESS_TOKEN>" \
  https://login.stanford.edu/idp/profile/oidc/userinfo
```

### Database issues

```bash
kubectl -n ais-xnat logs xnat-web-0-postgresql-0
```

## Plugins

Plugins in the `plugins/` directory are copied to `/srv/xnat-local-storage/xnat/plugins/` during installation.

**Pre-installed plugins:**
- `container-service-3.7.2-uq-fat.jar` - Container service plugin

**To add more plugins:**

1. Place JAR files in `plugins/` before running install, OR
2. Copy manually after installation:

```bash
# Copy plugin jar to local XNAT storage
sudo cp my-plugin.jar /srv/xnat-local-storage/xnat/plugins/

# Restart XNAT to load new plugins
kubectl -n ais-xnat rollout restart statefulset xnat-web
```

Emergency recovery note: If OIDC ever breaks and you can't log in, you can re-enable local login via:

```
sudo kubectl -n ais-xnat port-forward svc/xnat-web 8081:80 &
# Then from another session:
curl -u admin:<password-from-xnat-archiver-creds-secret> -X POST -H "Content-Type: application/json" \
  -d '{"enabledProviders": ["localdb", "stanford"]}' \
  http://localhost:8081/xapi/siteConfig
```
