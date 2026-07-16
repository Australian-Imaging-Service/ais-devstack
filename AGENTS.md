# AIS-XNAT Deployment for k3s

XNAT deployment on k3s with node-local storage for the Australian Imaging Service.

### Important guidelines:

- Never write credentials directly into the codebase and never commit them to github. Always use SOPS to encrypt secrets.
- Always test if you changes actually worked on the cluster
- Always check AGENTS.md file if the changes made should be documented in there.
- Always make sure there is local account admin and that it's not possible to login with local user accounts. The admin password is stored in the `xnat-archiver-creds` Kubernetes secret.

### Deployment Notes

- `kubectl` requires `sudo` on this machine (k3s kubeconfig at `/etc/rancher/k3s/k3s.yaml` is root-only)
- The XNAT application timezone is `America/Los_Angeles` (`timezone:` in `manifests/values.yaml`; the host/node stays on UTC). It was `Australia/Brisbane` until 2026-07-10, and XNAT stores local wall-clock times without offsets, so workflow/container timestamps from before then render 17 hours ahead of their true Pacific time. Account for this when auditing or purging old workflow rows by `launch_time`.
- XNAT runs as a StatefulSet (`xnat-web-0`), rollouts take a few minutes for the pod to terminate and restart
- The XNAT UI auto-logout is `sessionTimeout` in site config (stored in the XNAT database, not in this repo), set to `8 hours` on 2026-07-10 via `POST /xapi/siteConfig {"sessionTimeout": "8 hours"}`. If the site config is ever rebuilt it reverts to the 15-minute default; verify with `GET /xapi/siteConfig/sessionTimeout` or the `SESSION_EXPIRATION_TIME` cookie (duration in ms) on an authenticated response.
- **REST scripts must reuse one JSESSION per run and log out.** Every HTTP-Basic request mints a new server-side session that now lives 8 hours (see `sessionTimeout` above); `concurrentMaxSessions` is 1000 per user, and once exceeded XNAT rejects *correct* credentials with 401 while `xhbm_xdat_user_auth.failed_login_attempts` stays 0 and there is no lockout row — very confusing to diagnose. This locked out `admin` on 2026-07-11 (~1016 sessions, leaked mostly by project-owner-sync's ~70 Basic calls per 15-min run) the first night after the timeout increase. Pattern: `POST /data/JSESSION` once (Basic), send `Cookie: JSESSIONID=...` on all calls, `DELETE /data/JSESSION` at exit — project-owner-sync, qsmxt-scan-link-sync, and platform-monitor now do this (container-service-project-sync and the GCS archiver always did). Recovery when locked out: `edge-uploader` is **no longer an admin** (demoted to project-Owner-only on 2026-07-12), so the old "authenticate as another admin and `DELETE /xapi/users/active/admin`" path is gone — instead restart Tomcat to drop all server-side sessions: `sudo kubectl -n ais-xnat rollout restart statefulset/xnat-web` (a few minutes of downtime). `GET /xapi/users/active/<user>` (admin) returns the live session list. The platform monitor's `xnat-sessions` check warns when admin/edge-uploader exceed `XNAT_SESSION_WARN` (default 500) active sessions.
- Always use `--post-renderer ./manifests/kustomize.sh` with helm commands — it applies XNAT storage volume mount patches
- After helm upgrade, verify with: `sudo kubectl -n ais-xnat rollout status statefulset/xnat-web`
- XNAT archive storage uses static `local` PVs pinned to `xnat-host` under `/srv/xnat-local-storage`. The in-cluster NFS server is legacy only and should not be in XNAT/Jupyter's write path.
- Project archive directories must be explicitly mounted in `manifests/kustomization.yaml` and mirrored in `jupyterhub/2-xnat-mount-mapping.yaml`. If an existing project has data in the pod-local `/data/xnat/archive/<project>` path, copy it to `/srv/xnat-local-storage/gpfs/archive/<project>` before adding the mount, otherwise the rollout will hide or lose that local-only data.
- JupyterHub XNAT launches keep the Jupyter file-browser root at `/home/jovyan`. XNAT data mounts remain available at their original `/data/...` targets and are also mirrored under `/home/jovyan/xnat-data/...`; JupyterLab opens in the mirrored XNAT data target, or `/home/jovyan` when no XNAT data is mounted.
- JupyterHub allows two XNAT named servers per user. Keep `cull.removeNamedServers: true` enabled so stopped timestamped servers are removed instead of blocking new launches.
- XNAT Container Service uses the host Docker daemon through `/var/run/docker.sock`, mounted by `manifests/kustomization.yaml`. Docker runs containers on the host, so host paths must match XNAT's visible paths. Keep the host-side `/data/xnat` symlink mirror in sync with XNAT archive/build mounts, especially when adding new project archive mounts.
- `manifests/gcs-fuse-mount.yaml` runs `xnat-gcs-fuse`, which mounts `gs://xnat-lucas-archive` read-only at `/srv/xnat-local-storage/gpfs/object-store` and exposes it in XNAT/Jupyter as `/data/xnat/object-store`. Keep the host mirror symlink `/data/xnat/object-store -> /srv/xnat-local-storage/gpfs/object-store` in place for Container Service host-Docker jobs. The archiver may replace verified local archive files with symlinks into `/data/xnat/object-store/sessions/<project>/<session>/...`; keep catalog/session XML files local and verify the FUSE mount before enabling bulk offload.
- XNAT Container Service pipelines are stored in `container-service/commands/` and installed via `scripts/install-mriqc-container-service.sh`. The bundle includes `xnat/dcm2bids-session:1.5.1` for DICOM-to-NIFTI/BIDS resources, scan-level `xnat/dcm2niix:1.6`, `nipreps/mriqc:24.0.2` through `xnat2bids`, `nipreps/fmriprep:25.2.5` through `xnat2bids`, `pennlinc/aslprep:26.0.3` through `xnat2bids`, Neurodesk `vnmd/qsmxt_8.3.2:20260421` through `xnat2bids`, Neurodesk `vnmd/musclemap_1.3.45:20260701`, and Neurodesk `vnmd/spinalcordtoolbox_7.3.0:20260605`. MRIQC, fMRIPrep, and ASLPrep wrappers must already have scan-level `NIFTI` resources and `BIDS` JSON sidecars; fMRIPrep and ASLPrep run with `--fs-no-reconall` by default so no FreeSurfer license secret is required by these wrappers. QSMxT (`qsmxt-session`, command version `8.3.2-ais.2`) no longer uses the `xnat2bids-setup` step: it mounts the session's DICOM archive directly at `/input` and converts to BIDS inside the container (`qsmxt.cli.dicom_sort` — invoked as `python -c "from qsmxt.cli.dicom_sort import main; main()"` since the module has no `__main__` guard — then `dicom-convert --auto_yes`) before running `qsmxt --premade gre --do_qsm`, so no pre-existing `NIFTI`/`BIDS` scan resources are required. It relies on QSMxT's own heuristics to identify multi-echo GRE `part-mag`/`part-phase` (`MEGRE`) QSM series and does not depend on the site/project BIDS map. Because the session DICOMs are object-store symlinks, the read-only `/data/xnat/object-store` bind (below) must be present for the direct mount to resolve. The patched Container Service plugin jar adds a read-only `/data/xnat/object-store` Docker bind mount when that path exists, so scan-level dcm2niix, MuscleMap, and Spinal Cord Toolbox can follow absolute symlinks into the object store without rehydrating files; keep `plugins/patches/container-service-object-store-bind.patch` aligned with the jar. Scan-level MuscleMap and Spinal Cord Toolbox process the first `.nii` or `.nii.gz` file in lexical order. Each now exposes a single scan wrapper that always converts the scan's `DICOM` resource to NIfTI at launch time rather than assuming a pre-existing `NIFTI` resource: `spinalcordtoolbox-deepseg-dicom-scan` (label "Spinal Cord Toolbox") and `musclemap-dicom-scan` (label "MuscleMap"). Both use the `docker-setup` command in `container-service/commands/dcm2niix-setup.json` (image `xnat/dcm2niix:1.6`) via `via-setup-command`, so dcm2niix converts the `DICOM` resource into the tool's input mount at launch and no persistent `NIFTI` resource is created. The earlier NIfTI-only wrappers (`spinalcordtoolbox-deepseg-scan`, `musclemap-scan`) and the BIDS/`xnat2bids-setup` session wrapper (`musclemap-session`) were removed. Note the internal command names stay `spinalcordtoolbox-deepseg` and `musclemap-nifti` even though only the DICOM wrapper remains. There is likewise exactly one scan-level `dcm2niix` command (`container-service/commands/dcm2niix-scan.json`, version `1.6-ais.1`, wrapper `dcm2niix-scan`) and one `xnat2bids` setup command (version `1.4`); older stray duplicates once coexisted (`dcm2niix` v1.5 made the per-scan menu show `dcm2niix` twice, and a second `xnat2bids` v1.3 made the `via-setup-command: xnat/xnat2bids-setup:1.4:xnat2bids` reference ambiguous). If a duplicate command name reappears (`GET /xapi/commands`), delete the older/non-repo version with `DELETE /xapi/commands/<id>`. Keep `dcm2niix-setup` uploaded/public in the installer alongside `xnat2bids-setup`; setup commands have no XNAT wrapper to enable. DICOM-to-BIDS depends on a site or project BIDS map at `/data/config/bids/bidsmap` or `/data/projects/<project>/config/bids/bidsmap`. The installer enables wrappers site-wide and for existing projects; `manifests/container-service-project-sync.yaml` keeps wrappers enabled for future projects.
- Container launch status: the Container Service jar is also patched with `plugins/patches/container-service-single-launch-tracking.patch` (JS resources inside the jar) so single container launches post to the `bulklaunch` endpoint, get a `bulk-launch-id`, and show live progress in XNAT's Processing activity panel — the same tracking bulk launches always had. The patch also adds `XNAT.plugin.containerService.viewContainerLogs` (site-wide container log viewer dialog) and a fallback `XNAT.plugin.batchLaunch.viewWorkflowDetails` (the batch-launch plugin that normally defines it is not installed). The Active Processes banner on report pages is overridden via `templates/screens/workflow_alert.vm`, written into Tomcat at pod init by the `xnat-web-init` ConfigMap (`manifests/configmap.yaml`); it adds `[View Logs]` links for container workflows (the workflow `comments` field holds the Docker container hash, which `/xapi/containers/{id}/logs/{file}` accepts directly). When a workflow has no linked container, the fallback fetches `/data/workflows/{id}` and distinguishes still-queued runs from `Failed (Staging)` runs (Docker create failed before a container existed, so there are no logs) and shows the workflow `details`. Log access is enforced server-side: the launching user, project owners, and admins. Keep both jar patches applied when rebuilding the fat jar, and remember browsers may cache the old launcher JS after a jar update (hard refresh). Site SMTP is unconfigured (`localhost:25`; GCP blocks port-25 egress), so email notifications for container completion are deliberately not implemented.
- Docker create timeout: `DockerControlApi` builds the docker-java/OkHttp client with a hardcoded 4.5 s `readTimeout`, which makes `POST /containers/create` fail with `SocketTimeoutException` → workflow `Failed (Staging)` when a large Neurodesk image (spinalcordtoolbox, musclemap, fmriprep, qsmxt) is still pulling/extracting on a busy host, leaving an orphaned `Created` container the Container Service never tracks (`docker rm` it, then re-run). The same patch file raises that constant to **300000 ms (5 min)**. It was originally an in-place `sipush` swap to 32000 ms (`11 11 94` → `11 7D 00`), but a ~38 GB image (spinalcordtoolbox 7.3.0) still tripped 32 s while extracting, and `sipush` caps at 32767 ms; the current patch instead appends a new `Integer` constant to the class constant pool and swaps `sipush 32000` for `ldc_w` (both 3 bytes, so no bytecode offsets / StackMapTable / Code length shift — no source rebuild needed). Re-apply and verify per the notes at the bottom of `plugins/patches/container-service-single-launch-tracking.patch`: there is no `javap` on the host, so validate by re-parsing the class (constant_pool_count == old+1, appended `Integer==300000`, instruction at the readTimeout site == `13 08 55`) and confirm the plugin loads (no `VerifyError`/`ClassFormatError` in the `xnat-web` log) and `GET /xapi/docker/server` returns `"ping":true` after the restart. Pre-pulling the big images (or setting the Docker server config to pull on init; `pull-images-on-xnat-init` is currently `false`) also avoids racing create against a fresh pull.
- Container tracking stuck at `Created` / event poller poisoned by future timestamp: the Container Service tracks container start/die via a Docker event poller that runs every ~10 s and calls `GET /events?since=<last_event_check_time>&until=<now>`. The `since` comes from `xhbm_docker_server_entity.last_event_check_time`, stored as a **naive** timestamp in the XNAT application timezone. If that column ever holds a value in the future relative to real UTC, Docker rejects every poll with `Status 400: "since time (…) cannot be after until time (…)"` (logged on the `docker-java-stream-*` thread as `ERROR ... Error during callback`), the poller never advances, and **every** container launched afterward runs to completion on the host but is never finalized — it stays `Created`, its workflow stays `Created` (Active Processes banner never clears), and its outputs are never uploaded. `GET /xapi/docker/server` still returns `"ping":true`, so the platform-monitor Docker check does not catch this. This happened on 2026-07-10 when the app timezone changed `Australia/Brisbane → America/Los_Angeles`: container 19's event rows in `xhbm_container_entity_history` had been written as Brisbane-local wall-clock and were then read back as LA-local, so `last_event_check_time` was poisoned ~17 h into the future (`since` landed ~14 h ahead of `until`). Recovery: (1) rescue any already-finished-but-stuck run with `POST /xapi/containers/<id>/finalize` (admin) — this uploads its outputs and closes the workflow; (2) reset the checkpoint in postgres (pod `xnat-web-postgresql-0`, db/user `xnat`, password in `xnat-web-postgresql` secret key `password`, `psql` at `/opt/bitnami/postgresql/bin/psql`): `UPDATE xhbm_docker_server_entity SET last_event_check_time = (now() at time zone 'America/Los_Angeles') - interval '10 minutes';` — the timezone in that expression must match the app timezone; (3) **restart `xnat-web`** — the entity is cached in the JVM and only reloaded from the DB at startup, so a DB update alone does not take effect. Verify: no new `cannot be after` lines in the `xnat-web` log and `last_event_check_time` now trails real time by ~one poll interval (a few seconds), which only happens on successful (non-400) polls.
- `manifests/project-owner-sync.yaml` keeps `brosnan` and `edge-uploader` in the XNAT `Owners` group for every current and future project. The `edge-uploader` ownership is required because the `xnat-upload` alias token inherits that user's project permissions. The sync runs every 15 minutes using the admin credentials from `xnat-archiver-creds`; apply it with `sudo kubectl apply -f manifests/project-owner-sync.yaml` and trigger a manual job after changes to verify. The same sync also grants group-derived ownership: ais-edge routes DICOMs with PatientID `<subject>@<group>/<project>`, the group survives in each session's `dcmPatientId`, and when the group name matches an enabled XNAT user (e.g. `polimeni`), that user is made an Owner of every project holding that group's sessions. Groups without a matching XNAT user are skipped and logged; creating the user later activates ownership on the next sync. Note `/xapi/users/<name>` returns HTTP 500 (not 404) for unknown users — check membership against the `/xapi/users` list instead.
- `manifests/qsmxt-scan-link-sync.yaml` runs the `qsmxt-scan-link-sync` CronJob (ais-xnat, every 15 min) which attaches QSMxT output to the phase scan it was derived from. QSMxT is a session-level Container Service wrapper, so its Chimap lands in a session-level `QSMXT` resource with no link to the source GRE phase scan (XNAT's output handler can't attach to a scan because QSMxT discovers the phase/magnitude series internally — there is no scan input at launch). The job globs the archive for `*/RESOURCES/QSMXT/qsmxt-*/sub-*/ses-*/anat/*_Chimap.nii`, reads each Chimap's `.json` sidecar `SeriesNumber` (QSMxT copies it from the phase series), resolves that to the XNAT scan, and creates a scan-level `QSM` resource holding the Chimaps as **hard links** into the same archive filesystem (no byte duplication; XNAT `lstat`s catalog entries, so a hard link reports the true size while a symlink would report the ~180-byte link-path length — verified: `populateStats` re-stats and reverts any manually-corrected symlink sizes, so symlinks can't hold correct sizes). If a source Chimap has already been offloaded to an object-store symlink, it falls back to a symlink at the same target. Idempotent (skips scans already carrying the files); pure REST + filesystem on stock `python:3.12-alpine`, admin creds from `xnat-archiver-creds`, archive via the `pv-xnat-gpfs` RWX PVC at `/data/xnat`. Key detail: `GET .../scans/<id>/resources/<label>/files` returns **HTTP 200 with an empty Result for a non-existent resource**, so resource existence must be decided from the resources *list* (`GET .../scans/<id>/resources`), not the files listing — deciding from the files endpoint makes the job create bare on-disk dirs with no registered XNAT resource/catalog. Mapping assumes the DICOM-archived scan ID equals the phase `SeriesNumber` (XNAT's default); the job verifies the scan exists and logs/skips if not, so a mismatch is reported rather than mis-attached. Manual trigger: `sudo kubectl -n ais-xnat create job --from=cronjob/qsmxt-scan-link-sync qsmxt-scan-link-sync-manual-$(date +%s)` (add env `DRY_RUN=1` on a one-off job to report without writing). The job must mount the object-store FUSE hostPath (`/srv/xnat-local-storage/gpfs/object-store`) as its **own volume** at `/data/xnat/object-store` (same pattern as xnat-web): the gcsfuse submount does *not* propagate through the recursive bind of the `pv-xnat-gpfs` PV even with `mountPropagation: HostToContainer`, so without the dedicated bind the nightly archiver's offloaded Chimap/sidecar symlinks dangle inside the pod and every run fails on `cannot read SeriesNumber` (this broke on 2026-07-10 the first night the archiver offloaded QSMXT resources). Any future pod that must follow object-store symlinks needs the same dedicated hostPath mount.
- `manifests/bids-app-autoconvert.yaml` runs the `bids-app-autoconvert` CronJob (ais-xnat, every 15 min) which reactively "heals" the BIDS-App wrappers (`mriqc-session`, `fmriprep-session`, `aslprep-session`). Those wrappers run `xnat2bids-setup`, which only *collects* pre-existing scan-level `NIFTI` + `BIDS`-sidecar resources into a BIDS tree; on a DICOM-only session the setup step finds nothing and the launch dies as **`Failed (Setup)`** (the main container carries that status; its `xnat/xnat2bids-setup:1.4` child is `Failed`, `subtype: docker-setup`, `parent-source-object-name: bids-in`) — opaque to users. We deliberately keep the convert-once model (persistent `NIFTI`/`BIDS` resources reused by all three apps) rather than making each app self-convert. The job queries `GET /xapi/commands` (to map the app + `dcm2bids-session-session` wrapper names → command/wrapper ids) and `GET /xapi/containers`, and for each session with a BIDS-App container stuck in `Failed (Setup)` it decides using **globally-monotonic container ids** as the ordering key (no external state, so no convert/relaunch loop): no BIDS resources and no conversion newer than the failed run → launch `dcm2bids-session` (`POST /xapi/commands/<id>/wrappers/<id>/launch` with `{"session":"/archive/experiments/<ID>", "overwrite":"False"}`); a `dcm2bids-session` still running → wait; a conversion Complete but still no `BIDS` resources (no BIDS-mappable series — e.g. spine/QSM/`MEGRE` protocols with no site/project bidsmap entry) → log `DEAD-END` and stop; `BIDS` now present and newer than the failed run → re-launch the app once, replaying the failed container's original inputs (`GET /xapi/containers/<id>` → inputs of `type` `wrapper-external`/`command`). BIDS-presence is decided from the scan **resources list** (`GET .../scans/<id>/resources`, any label upper-cased `== BIDS`), not the files endpoint (which returns HTTP 200 + empty Result for a missing resource). Reactive by design, so the user's first launch still shows a transient `Failed (Setup)` before the auto-heal completes over the next cycle(s); a dead-end session is re-checked (~one resources GET per scan) every cycle until it either gains a matching bidsmap entry or the failed run is superseded. The CS launch `POST` is accepted with the JSESSION cookie alone (no CSRF token needed, unlike state-changing `/xapi/users` calls); the job reuses one JSESSION and logs out. Stock `python:3.12-alpine`, stdlib only, admin creds from `xnat-archiver-creds`, no volumes. Manual trigger: `sudo kubectl -n ais-xnat create job --from=cronjob/bids-app-autoconvert bids-app-autoconvert-manual-$(date +%s)`; add env `DRY_RUN=1` **on the CronJob spec** (not via `kubectl set env` on an already-created job — the pod template is immutable) to report intended actions without launching. Note MRIQC only handles anatomical (T1w/T2w) and BOLD/DWI series, so a QSM/spine-only session is a permanent dead-end even after conversion.
- The site-wide BIDS map lives at `container-service/bidsmap/site-bidsmap.json` and is installed with `scripts/install-bidsmap.sh`. XNAT's dcm2bids map uses exact, case-insensitive `series_description` matches; avoid adding broad or guessed mappings for scouts, B1 maps, reports, ADC/TRACEW derivatives, or project-specific task names without checking the project protocol.
- The `xnat-web-init` ConfigMap also patches `logback.xml` at pod init to set `org.nrg.xnat.restlet.resources.QueryOrganizerResource` to `OFF`: xnatpy-based clients (the xnat-ingest uploader) request `columns=ID,URI` on every listing, XNAT serves the request but logs a spurious `Unknown alias "URI"` ERROR each time. logback has `scan="true"`, so the same edit can be applied to a running pod without a restart.
- OHIF viewer 3.7.2 is hotfixed in `manifests/configmap.yaml` during XNAT pod init so server-side metadata generation scans only `DICOM`/`secondary` resource paths, preserves original DICOM filenames in generated URLs, skips common raw/data extensions such as `.dat`, and skips files larger than 1 GiB by default (`OHIF_METADATA_MAX_SCAN_BYTES` can override). This prevents large raw data files in scan resources from being parsed as DICOM and OOMing Tomcat. Keep the XNAT probe values in `manifests/values.yaml` relaxed enough for synchronous OHIF metadata generation (`liveness.timeoutSeconds: 30`, `liveness.failureThreshold: 10`); the default 5-second single-failure liveness probe can restart Tomcat mid-generation.

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

### Token endpoint requires client_secret_basic (JupyterHub too)

Stanford's token endpoint only accepts HTTP Basic client authentication; credentials in the POST body (`client_secret_post`) get `400 invalid_request` with the opaque description `InvalidEvent` — the same error a wrong secret produces, so it's easy to misread as a bad credential. JupyterHub's oauthenticator (>=16, currently 17.4.0) defaults to `client_secret_post`, so `jupyterhub/5-jupyterhub-values.yaml` must keep `basic_auth: true` under `GenericOAuthenticator` (added 2026-07-12 after hub OIDC logins 500'd at `/jupyter/hub/oauth_callback`; the misconfig was latent until the secret-rotation hub restart plus new `JUPYTERHUB_CRYPT_KEY_HEX` forced fresh OAuth logins). To classify token-endpoint failures without a real login, POST a bogus code to the token endpoint with Basic auth: `invalid_grant` means client auth is fine; `InvalidEvent` means the auth method or secret is wrong.

Relatedly, the hub's username must match what the XNAT JupyterHub plugin creates (`stanford_<xnat-username>`, where the XNAT username is the email prefix). Stanford's `sub` is an opaque UUID, so `username_claim: "sub"` makes a browser OIDC login create a second hub user (`stanford_<uuid>@stanford.edu`) that then 403s on `/jupyter/user/stanford_<sunet>/...`. The `02a_stanford_username_claim` extraConfig snippet in `jupyterhub/5-jupyterhub-values.yaml` overrides `username_claim` with a callable returning the email prefix (mirroring XNAT's `[email_prefix]` patch); both fixes were latent until 2026-07-12 because the token-exchange failure meant no browser OIDC login had ever completed.

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

Idempotent. Creates the user (no site roles — least privilege; it removes a legacy `Administrator` role if present), creates the seed projects, makes the user an Owner of each, and stores credentials in the `edge-uploader-creds` k8s secret. Re-running against existing state is a no-op for the password. Env overrides: `XNAT_URL`, `EDGE_USER`, `EDGE_EMAIL`, `EDGE_PROJECTS`, `XNAT_NAMESPACE`.

### What it provisions

- **Service account**: `edge-uploader` (localdb), email `mail.neurodesk@gmail.com`, **no site roles** (site-wide `Administrator` was removed 2026-07-12 — uploads, scan-UID backfill, and OHIF metadata regeneration all work with the project Owner rights that `project-owner-sync` maintains on every project)
- **Seed projects** (Owner = `edge-uploader`): `polimeni`, `ennis`, `dicomtest`, `misc` (catch-all for un-routed AETs), `Siemens_cimax`, `openrecon`
- **k8s secret** `ais-xnat/edge-uploader-creds` with keys `username`, `password`, `xnat_url`, `email`

### Why REST works despite OIDC-only login

`siteConfig.enabledProviders` is `["stanford"]` — the web login form refuses localdb. But REST `POST /data/JSESSION` and HTTP Basic on `/xapi/*` / `/data/*` still accept localdb credentials. So service accounts work without weakening the OIDC enforcement on humans.

### DICOM metadata pull workflow failures

If XNAT shows many failed `Pulled Data from DICOM` workflows after ais-edge uploads, check the `xnat-upload/xnat-ingest-upload` deployment. Catalog-only `DICOM` resources in the archive make XNAT's `pullDataFromHeaders=true` endpoint fail with `Unable to locate DICOM or ECAT files`; the ingest uploader should skip that header-pull step unless local DICOM objects are actually present. Active stale failures can be dismissed by marking `wrk_workflowdata.status` as `Failed (Dismissed)` for `pipeline_name='Pulled Data from DICOM'`.

Use `scripts/purge-xnat-workflows.sh` for workflow table cleanup. It defaults to a dry-run, matches only `Complete` workflows older than 30 days, compares `launch_time` in the XNAT application timezone, and deletes paired `wrk_workflowdata_meta_data` rows only after deleting the workflow rows that referenced them. For the common high-volume audit noise from bulk archive operations, review a dry-run such as `./scripts/purge-xnat-workflows.sh --older-than-days 1 --pipeline "Uploaded File" --pipeline "Catalog(s) Refreshed"` before adding `--execute`. Do not purge `Running` or recent container-service workflow rows.

`manifests/xnat-project-provisioner.yaml` runs the `xnat-project-provisioner` CronJob in `xnat-upload` every minute, ahead of xnat-ingest's 5-minute staged quiet window. It scans the ready/staged SeaweedFS prefixes and creates any missing, syntactically valid XNAT project with the rotating `xnat-credentials` alias (the underlying `edge-uploader` is allowed to create projects and becomes an Owner, so no admin credentials are copied into `xnat-upload`). It ensures `brosnan` and `edge-uploader` remain Owners and, for PatientID routes of the form `<subject>@<group>/<project>`, requests and verifies the matching group user as an Owner. XNAT returns HTTP 200 even when adding a nonexistent user, so the job verifies the project users list; a missing group user is logged as deferred and the existing `project-owner-sync` adds it after that user exists. The staged prefix is the provisioning approval boundary: automatic edge labeling still obeys `AIS_EDGE_AUTO_IMPORT_ALLOWED_PROJECTS`, while an explicit/manual `xnat-ingest-ready` label intentionally admits a project outside that automatic allowlist. Apply with `sudo kubectl apply -f manifests/xnat-project-provisioner.yaml`; manual trigger: `sudo kubectl -n xnat-upload create job --from=cronjob/xnat-project-provisioner xnat-project-provisioner-manual-$(date +%s)`.

The `xnat-ingest-upload` deployment also hot-patches `xnat-ingest` idempotency (`ais-devstack/empty-resource-hotfix=xnat-ingest-empty-resources-not-uploaded-v4`) so existing empty or partial XNAT resources do not count as uploaded. It compares staged resource manifest file names with XNAT catalog entries before skipping an upload. If an upload is interrupted and leaves truncated files outside the XNAT catalog, delete the partial XNAT experiment/resource with `removeFiles=true` and let the staged data re-upload; do not move the staged prefix to `uploaded/` until XNAT file counts match the staged file count.

The in-cluster `xnat-ingest-upload` deployment is also hot-patched with `ais-devstack/scan-uid-backfill=xnat-ingest-backfill-scan-uids-v4`. The hook runs before staged sessions are archived, including immediately after both successful and failed upload attempts so a session created during the current attempt is backfilled before its staged source moves to `uploaded/`. It resolves staged session labels to `XNAT_E...` experiment IDs through the project/subject experiment listing (direct `/data/experiments/<label>/...` calls can return HTTP 500), waits until XNAT file counts match staged file counts, requests scan columns as `ID,UID`, range-reads one DICOM header for each scan whose UID is blank, extracts top-level `SeriesInstanceUID`, and writes `xnat:mrScanData/UID`. Keep equivalent behavior if the deployment is rebuilt; otherwise a newly created project/session can archive successfully while leaving OHIF with zero instances.

The rsl60 edge `xnat-ingest-sort` deployment keeps `--wait-period 1800` and `AIS_EDGE_AUTO_IMPORT_WAIT_PERIOD=1800`; its `xnat-ingest-sort-wrapper` ConfigMap auto-labeler waits for an unchanged Orthanc study snapshot before applying `xnat-ingest-ready`. Preserve this when rebuilding so slow OpenRecon/derived series are not staged before the study is complete.

### SeaweedFS ingest bucket lifecycle

The `xnat-ingest-upload` wrapper archives verified staged sessions to `uploaded/<stamp>/<session>/` in the SeaweedFS ingest bucket (`/data/seaweedfs` on the host). Those copies are redundant once the nightly GCS archiver has backed the session up, and left alone they grow by hundreds of GB per month. `manifests/ingest-uploaded-retention.yaml` runs daily at 4am (after the 2am backup): it deletes `uploaded/` copies older than 7 days whose session has a GCS `.backup_complete` marker (checked through the object-store FUSE hostPath) and clears stale `.uploads` multipart debris; copies without a marker are kept and reported. When debugging bucket usage, note the SeaweedFS filer double-counts nothing but `weed shell` `fs.du` returns 0 for paths given with a trailing slash — use `fs.du /buckets/ingest-bucket` (no trailing slash). Filer-level deletes only mark needles; disk is actually freed by volume vacuums, which `manifests/seaweedfs-vacuum.yaml` (`seaweedfs-vacuum` CronJob, seaweedfs namespace, daily 5am — an hour after retention so needle deletions have propagated to the volume servers) runs automatically: it selects volumes from `volume.list` with ≥64 MiB garbage or ≥25% garbage ratio (`VACUUM_MIN_DELETED_MB` / `VACUUM_MIN_RATIO`) and vacuums each explicitly by id. SeaweedFS 3.99 gotchas baked into that script, equally relevant when vacuuming manually: `weed shell` commands need `lock` first (without it they silently do nothing); the threshold sweep `volume.vacuum -garbageThreshold 0.1` skips near-100%-garbage volumes, so vacuum per `-volumeId`; even with `-volumeId` the default `garbageThreshold` (0.3) still applies and silently skips volumes below it, so pass `-garbageThreshold 0.001` explicitly; and `weed shell` bootstraps over master gRPC at port+10000, so the `seaweedfs` Service must keep exposing 19333 (master-grpc) and 18888 (filer-grpc) — added 2026-07-11 by live patch; the seaweedfs Deployment/Service manifests are not in this repo — or the shell hangs on `WaitUntilConnected`. Failure mode seen 2026-07-11: a hung vacuum goroutine leaves the master's in-memory vacuum lock held forever, so every `volume.vacuum` (including the master's own periodic sweep) becomes a silent no-op logging `Vacuum is already running` in the master log while `weed shell` still exits 0. The CronJob detects this (selected volumes still carry `deleted_byte_count` afterwards) and fails the job so the platform monitor alerts; recovery is `sudo kubectl -n seaweedfs rollout restart deploy/seaweedfs` (check the edge s3-uploader and central xnat-ingest-upload are idle first). Manual trigger: `sudo kubectl -n seaweedfs create job --from=cronjob/seaweedfs-vacuum seaweedfs-vacuum-manual-$(date +%s)`. Archiving staged prefixes leaves empty directory skeletons behind that make the wrapper's archive step churn; they are safe to delete once a subtree has no file entries.

A successful SeaweedFS vacuum commit can take several volume heartbeats to
appear in `volume.list` (observed 2026-07-15). The CronJob's post-vacuum check
therefore retries for up to about one minute; an immediate one-shot check can
false-fail even though the compact revisions advance moments later.

### Manual scanner pull into Orthanc and XNAT

When a Cima3T series was acquired but not sent to Orthanc, pull it from the edge
sort pod rather than from the central XNAT host. Use the edge kubeconfig
`/home/uqsbollm/ais-edge/kubeconfig-edge-rsl60` and run REST helper scripts
inside `deploy/xnat-ingest-sort` so Orthanc is reachable. Read the authenticated
Orthanc URL from the live deployment into an environment variable and pass it to
the helper process; do not echo it, store it in files, or copy credentials into
the repo.

For Cima3T, the permanent Orthanc modality may time out or reject C-FIND/C-MOVE
if it uses an empty local AE title. Create a temporary modality for the pull
with the Cima3T host/port, remote AET `AWP2130612`, local AET `rsl60`, and a
longer timeout such as 60 seconds. C-ECHO should return 200 before querying.
Delete the temporary modality after the pull.

Query Cima3T at `Level=Series` using the routed `PatientID`
(`<subject>@<group>/<project>`), the scanner `StudyDate`, and a narrow
`SeriesDescription` wildcard when possible. Do not assume the DICOM `StudyDate`
is today's date; appended derived series can keep the original study date. Save
each answer's `SeriesNumber`, `SeriesDescription`, `SeriesInstanceUID`, and
`NumberOfSeriesRelatedInstances`. Before retrieving, compare each
`SeriesInstanceUID` with local Orthanc `/tools/find` at `Level=Series` so only
missing or incomplete series are retrieved. Retrieve with target AET `rsl60`,
then poll local Orthanc until each series has the expected instance count.

After retrieval, remove `xnat-ingest-skip` and ensure `xnat-ingest-ready` is set
on the Orthanc study. The next sorter loop should stage it, mark skip again, and
route it from the fallback `misc...` label to the routed session label such as
`openrecon.<subject>.<visit>`. Watch the edge sorter, edge `s3-uploader`, and
central `xnat-upload/xnat-ingest-upload` logs. The edge uploader first copies to
`incoming/edge-rsl60/...`, then promotes to `staged/...`; the central uploader
waits for the configured 300-second quiet window before importing.

Verify completion in XNAT through authenticated REST from the upload pod:
check the experiment scan list, per-scan `DICOM` resource file counts, and the
expected new scan numbers. The central uploader should then archive the staged
prefix to `uploaded/<timestamp>/<session>/`. If the scan UID backfill hook ran
too early and new `xnat_imagescandata.uid` values are blank, populate only those
blank rows from the recorded `SeriesInstanceUID` values and verify the update.
Regenerate OHIF metadata with `POST
/xapi/viewer/projects/<project>/experiments/<experiment-id>`, then `GET` the same
endpoint and verify the expected series and instance counts. OHIF metadata
generation is synchronous and can take more than a minute.

For OHIF sessions that show studies/series but no instances, check `xnat_imagescandata.uid`: OHIF maps DICOM `SeriesInstanceUID` to XNAT scan IDs through that field. After restoring catalog-only sessions, regenerate OHIF metadata and verify instance counts; if instances remain zero, populate scan UIDs from the DICOM `SeriesInstanceUID` values and regenerate metadata. Catalog audits should check both zero `xnat_abstractresource.file_count` and nonzero file counts whose catalog XML is missing or has no `cat:entry` elements.

### GCS archiver failures

The `xnat-gcs-archiver` CronJob intentionally skips sessions with zero XNAT file records before backing up. Many historical session shells have no files and no `.backup_complete` marker; treating those as backup failures causes the nightly job to fail even though there is nothing to back up.

The archiver queries both scan-level files (`/scans/ALL/files`) and experiment-level resources (`/files`) to decide whether a session has data, then backs up from the local archive directory by default (`BACKUP_SOURCE_MODE=local`) instead of downloading ZIPs through XNAT REST. `BACKUP_SOURCE_MODE=rest` is retained as a rollback path. Experiment-level resources are required for sessions such as `openrecon/test-upload`, where the session has a top-level `FILES` resource but no scan files. With `OFFLOAD_AFTER_BACKUP=1`, the CronJob only replaces local files with symlinks after the object-store file is visible through the FUSE mount and has the same byte size. Keep catalog/session XML and ingestion logs such as `dcmtoxnat.log` local. Bulk historical offload jobs should also set `OFFLOAD_EXISTING_BACKUPS=1` and `REPAIR_INCOMPLETE_BACKUPS=1`; if a stale `.backup_complete` marker exists but local files have no matching object, the job removes that marker, re-syncs the session, and retries the offload.

The `.backup_complete` marker in GCS is not trusted on its own: sessions can gain scans after their first backup (appended OpenRecon/derived series). When any regular local file in a session is newer than the marker object's creation time, the archiver logs `STALE`, removes the marker, and re-syncs the session incrementally before offloading again. Local `gsutil rsync` runs with `-e` so already-offloaded symlinks are never followed back through the FUSE mount. Many historical sessions were offloaded against the old REST-ZIP bucket layout (`sessions/<project>/<label>/<label>/scans/...`); ~150k live archive symlinks point at those objects, so never delete old-layout prefixes from the bucket. The archiver script is baked into the `xnat-gcs-archiver:latest` image — after editing `archiver/xnat-archive-to-gcs.sh`, rebuild with `docker build -t xnat-gcs-archiver:latest archiver/` and `docker save xnat-gcs-archiver:latest | sudo k3s ctr images import -`.

The nightly Postgres dump at the end of the archiver run is **mandatory and fails the job loudly** (hardened 2026-07-12; it previously logged `SKIP` and exited 0 when `DB_PASS` was unset). The dump goes to a local file first and is only uploaded to `gs://<bucket>/db-backups/` after passing `gzip -t`, a minimum-size check (`DB_DUMP_MIN_BYTES`, default 1 MB), and a check for pg_dump's `PostgreSQL database dump complete` trailer, then the uploaded object size is compared — so a mid-stream failure can never leave a truncated object in GCS posing as a fresh backup. Missing `DB_PASS`, a failed dump, or a failed upload all exit 1 (set `DB_BACKUP_REQUIRED=0` for an explicit opt-out). Last 7 dumps are retained. The platform monitor alerts both on the failed job (`cronjob-failing`) and independently on dump staleness (`db-backup` check). A quick way to exercise only the dump path: run a one-off job from the cronjob with `SESSION_ID_FILTER=ZZZNOMATCHZZZ` (skips all sessions, then dumps).

**DB restore drill (measured 2026-07-12, dump `xnat-20260712-004202.sql.gz`, 25.7 MB gz / 295 sessions / ~4.3k scans): restore takes ~1m25s; total DB RTO ≈ 5 min** (throwaway `bitnamilegacy/postgresql:16.4.0-debian-12-r28` pod with the object-store hostPath bind + `CREATE ROLE xnat LOGIN; CREATE DATABASE xnat_restore OWNER xnat;` + `zcat <dump> | psql -U postgres -d xnat_restore`). Row counts (experiments/subjects/scans/resources/projects/users) matched live exactly. **RPO: up to ~24h** — one dump per night at 02:00 UTC; anything written after the last dump is lost in a DB-loss event. Expect exactly 3 benign stderr lines when restoring with psql 16: the archiver image's newer pg_dump (17.x) emits `\restrict`/`\unrestrict` and `transaction_timeout`, which older psql skips — restore with psql ≥ 17 for a clean log. Note the dump alone is not a full service restore: archive files (GCS), the k3s manifests (this repo), and the hand-built node itself are separate concerns — the node has no IaC, so full-node RTO is unmeasured and much longer.

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

Rotate the password (re-stores the secret). Note `PUT /xapi/users/<user>/password` does **not** exist on this XNAT (404, verified 2026-07-12); set the password with a JSON `PUT /xapi/users/<user>` instead. Also use HTTP Basic for this call — with JSESSION cookie auth XNAT rejects state-changing `/xapi` calls (CSRF) and curl reports nothing useful:

```bash
NEW_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
curl -sS -u "admin:${ADMIN_PW}" -X PUT \
  "https://xnat-lucas.neurodesk.org/xapi/users/edge-uploader" \
  -H "Content-Type: application/json" -d "{\"password\":\"${NEW_PW}\"}"
sudo kubectl -n ais-xnat delete secret edge-uploader-creds
sudo kubectl -n ais-xnat create secret generic edge-uploader-creds \
  --from-literal=username=edge-uploader \
  --from-literal=password="$NEW_PW" \
  --from-literal=xnat_url=https://xnat-lucas.neurodesk.org \
  --from-literal=email=mail.neurodesk@gmail.com
```

## Platform monitoring & alerts

`manifests/platform-monitor.yaml` runs the `platform-monitor` CronJob (ais-xnat namespace, every 15 minutes) which emails `mail.neurodesk@gmail.com` via Gmail SMTP. It checks: node disk usage (warn 80% / crit 90%), unhealthy pods and container restarts in the core namespaces, failed k8s Jobs and stale CronJobs (no success within ~1.5× their schedule period; CronJob-owned job failures are keyed as a `cronjob-failing:<ns>/<name>` issue — alert once, re-alert per `REALERT_HOURS` (24h), RECOVERED when the latest run succeeds — instead of a per-job event, since a failing 15-min CronJob would otherwise email every run; only standalone Jobs still produce one-time per-job events), XNAT reachability (in-cluster service and public URL), public TLS certificate expiry (<14 days), Container Service Docker ping, XNAT active server-side session counts for admin/edge-uploader (warn above `XNAT_SESSION_WARN`, default 500 — catches JSESSION leaks before the `concurrentMaxSessions` 401 lockout; note `GET /xapi/users/active/<user>` returns HTTP 304, not an empty list, when the user has zero active sessions — the check treats 304 as 0), newly failed XNAT workflows (`wrk_workflowdata`, dismissed excluded), pending project access requests (`xs_par_table` rows with `approved IS NULL` — these re-alert daily until approved/denied in the project's Access tab), and ingest `staged/`/`incoming/` prefixes older than 24h (stuck uploader), and nightly Postgres dump freshness (`db-backup` issue when the newest `db-backups/xnat-*.sql.gz` in GCS is older than `DB_BACKUP_MAX_AGE_HOURS`, default 30, or suspiciously small — read through a dedicated hostPath bind of the object-store FUSE mount at `/object-store`, since the gcsfuse submount does not propagate through the recursive `/host` bind).

Behavior: one email per run batching NEW problems and one-time EVENTS; persistent problems re-alert every 24h and produce a RECOVERED notice when they clear; a daily digest at 8am `America/Los_Angeles` summarizes disk/pods/cronjobs/workflows/access-requests/ingest and acts as a dead-man's switch (no digest = the monitor itself is broken; check `sudo kubectl -n ais-xnat get jobs | grep platform-monitor`). Disk usage is reported once per underlying filesystem, so configured paths on the same node disk do not produce duplicate digest lines or capacity alerts. A failing check reports itself as a `check-error:<name>` issue rather than failing silently.

Operational notes:
- The script is baked into the local `xnat-platform-monitor:latest` image (`monitoring/platform-monitor.py` + `monitoring/Dockerfile`). After editing it: `sudo docker build -t xnat-platform-monitor:latest monitoring/ && sudo docker save xnat-platform-monitor:latest | sudo k3s ctr images import -` (or re-run `scripts/install-platform-monitor.sh`).
- SMTP credentials (Gmail app password) live only in the `platform-monitor-smtp` secret (keys `username`, `password`, `to`) — never in the repo. Rotate with `SMTP_PASSWORD=... ./scripts/install-platform-monitor.sh`.
- Alert dedup state is at `/srv/xnat-local-storage/monitoring/state.json` on the host; delete it to re-alert on everything currently broken.
- Manual run: `sudo kubectl -n ais-xnat create job --from=cronjob/platform-monitor platform-monitor-manual-$(date +%s)`. To test the digest, create a one-off job from the cronjob spec with env `FORCE_DIGEST=1`.
- Thresholds/targets are env vars on the CronJob container (`DISK_WARN_PCT`, `CERT_WARN_DAYS`, `STAGED_MAX_AGE_HOURS`, `REALERT_HOURS`, `DIGEST_HOUR`, `K8S_NAMESPACES`, ...); defaults are in `monitoring/platform-monitor.py`.

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
- `container-service-3.7.2-uq-fat.jar` - Container service plugin, patched with `plugins/patches/container-service-object-store-bind.patch` (Java: Docker launches can follow object-store symlink targets) and `plugins/patches/container-service-single-launch-tracking.patch` (JS: single launches show live progress in the activity panel; site-wide container log viewer)

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
