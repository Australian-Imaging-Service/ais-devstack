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
- The XNAT alias-token lifetime is `aliasTokenTimeout` in site config (stored in the XNAT database, not in this repo), set to `1 year` on 2026-08-12 via `POST /xapi/siteConfig {"aliasTokenTimeout": "1 year"}`. It was previously `2 days`; verify with `GET /xapi/siteConfig/aliasTokenTimeout` after a site-config rebuild.
- **REST scripts must reuse one JSESSION per run and log out.** Every HTTP-Basic request mints a new server-side session that now lives 8 hours (see `sessionTimeout` above); `concurrentMaxSessions` is 1000 per user, and once exceeded XNAT rejects *correct* credentials with 401 while `xhbm_xdat_user_auth.failed_login_attempts` stays 0 and there is no lockout row — very confusing to diagnose. This locked out `admin` on 2026-07-11 (~1016 sessions, leaked mostly by project-owner-sync's ~70 Basic calls per 15-min run) the first night after the timeout increase. Pattern: `POST /data/JSESSION` once (Basic), send `Cookie: JSESSIONID=...` on all calls, `DELETE /data/JSESSION` at exit — project-owner-sync, qsmxt-scan-link-sync, and platform-monitor now do this (container-service-project-sync and the GCS archiver always did). Recovery when locked out: `edge-uploader` is **no longer an admin** (demoted to project-Owner-only on 2026-07-12), so the old "authenticate as another admin and `DELETE /xapi/users/active/admin`" path is gone — instead restart Tomcat to drop all server-side sessions: `sudo kubectl -n ais-xnat rollout restart statefulset/xnat-web` (a few minutes of downtime). `GET /xapi/users/active/<user>` (admin) returns the live session list. The platform monitor's `xnat-sessions` check warns when admin/edge-uploader exceed `XNAT_SESSION_WARN` (default 500) active sessions.
- Always use `--post-renderer ./manifests/kustomize.sh` with helm commands — it applies XNAT storage volume mount patches
- After helm upgrade, verify with: `sudo kubectl -n ais-xnat rollout status statefulset/xnat-web`
- XNAT archive storage uses static `local` PVs pinned to `xnat-host` under `/srv/xnat-local-storage`. The in-cluster NFS server is legacy only and should not be in XNAT/Jupyter's write path.
- The complete XNAT archive tree is mounted from the static local `pv-xnat-gpfs` volume in one operation: `/srv/xnat-local-storage/gpfs/archive` on `xnat-host` is visible as `/data/xnat/archive` in XNAT and through the host mirror. Keep the host-side `/data/xnat/archive` symlink pointed at that top-level directory so Container Service host-Docker jobs resolve the same paths. This global mount is required because `xnat-project-provisioner` creates projects dynamically; do not reintroduce ordinary per-project archive mounts. JupyterHub uses the matching global `/data/xnat/archive` -> `archive` rule in `jupyterhub/2-xnat-mount-mapping.yaml`. Before 2026-07-22 the StatefulSet used a static per-project mount list: `mesovein3T` consequently wrote 64.47 GB into pod overlay and host-Docker saw an empty session, while `ivim` and `qpp` data also required recovery from retained ingest-bucket copies. If any data is ever found outside the global archive target, migrate and verify it before a rollout so the mount does not hide it.
- JupyterHub XNAT launches keep the Jupyter file-browser root at `/home/jovyan`. XNAT data mounts remain available at their original `/data/...` targets and are also mirrored under `/home/jovyan/xnat-data/...`; JupyterLab opens in the mirrored XNAT data target, or `/home/jovyan` when no XNAT data is mounted.
- JupyterHub allows two XNAT named servers per user. Keep `cull.removeNamedServers: true` enabled so stopped timestamped servers are removed instead of blocking new launches.
- JupyterHub launch failures can be caused by a broken per-user Longhorn home PVC even when the Hub and XNAT `xnat-service` API identity are healthy. On 2026-07-22/23 `cassidyl`'s first home volume was created while the node was under `ephemeral-storage` pressure and Longhorn's only disk was below its 25%-free scheduling threshold; the volume never acquired a healthy replica (`AttachVolume ... volume ... is not ready for workloads`), so the notebook timed out and stale named-server records later consumed the two-server limit. If Longhorn confirms a newly-created home volume has never held data, delete only that user's PVC so KubeSpawner recreates it; never delete an established user volume without recovering its data. A normally idle-culled volume is also `state=detached, robustness=unknown`, but has a non-empty replica `healthyAt` and empty `failedAt`; do not classify or delete it as broken. The platform monitor checks the XNAT-configured JupyterHub service token, `allUsersCanStartJupyter`, stale/stalled named servers, and unhealthy `jupyter-*` Longhorn volumes using that replica distinction.
- Longhorn is pinned to `v1.12.1` in `jupyterhub/2-install-longhorn.sh`. Do not reinstall `v1.11.0`: it has a confirmed instance-manager proxy connection leak that grew this node's instance manager to 13,103 MiB over 33 days. The permanent fix shipped in v1.11.1 and is included in v1.12.1; the live cluster was upgraded on 2026-08-25. Longhorn only supports one-minor-version upgrade steps and prohibits downgrades after a successful upgrade. Before changing Longhorn, verify every volume/replica is healthy, make application-consistent JupyterHub SQLite and edge-etcd snapshots, preserve the effective Helm values, and follow the official upgrade notes. Afterward verify the manager and engine versions, replicas in `RW`, empty replica `failedAt`, JupyterHub SQLite integrity, etcd endpoint health, and instance-manager memory over time.
- XNAT Container Service uses the host Docker daemon through `/var/run/docker.sock`, mounted by `manifests/kustomization.yaml`. Docker runs containers on the host, so host paths must match XNAT's visible paths. Keep the host-side `/data/xnat` symlink mirror in sync with XNAT archive/build mounts, especially when adding new project archive mounts.
- `manifests/gcs-fuse-mount.yaml` runs `xnat-gcs-fuse`, which mounts `gs://xnat-lucas-archive` read-only at `/srv/xnat-local-storage/gpfs/object-store` and exposes it in XNAT as `/data/xnat/object-store`. **Never mount this complete object-store into a Jupyter single-user pod.** The JupyterHub pre-spawn hook derives the narrowest authorized object-store scope from each XNAT task archive mount: a session archive mount gets only `/data/xnat/object-store/sessions/<project>/<session>`, while a task that already mounts a complete project archive gets only `/data/xnat/object-store/sessions/<project>`. Default/non-XNAT notebooks receive no object-store mount. The Hub alone has a read-only object-store index mount so it can omit scoped mounts for data that has not been offloaded. `jupyterhub/11-object-store-isolation-policy.yaml` enforces this at admission: a single-user pod may have no hostPath except an exact object-store project/session scope, so Kubernetes rejects a future global-mount regression before scheduling. Keep the host mirror symlink `/data/xnat/object-store -> /srv/xnat-local-storage/gpfs/object-store` in place for Container Service host-Docker jobs. The archiver may replace verified local archive files with symlinks into `/data/xnat/object-store/sessions/<project>/<session>/...`; keep catalog/session XML files local and verify the FUSE mount before enabling bulk offload.
- XNAT Container Service pipelines are stored in `container-service/commands/` and installed via `scripts/install-mriqc-container-service.sh`. The bundle includes `xnat/dcm2bids-session:1.5.1` for DICOM-to-NIFTI/BIDS resources, scan- and session-level `xnat/dcm2niix:1.6`, `nipreps/mriqc:24.0.2` through `xnat2bids`, local `xnat/fmriprep:25.2.5-ais.2` through `xnat2bids`, `pennlinc/aslprep:26.0.3` through `xnat2bids`, Neurodesk `vnmd/qsmxt_8.3.2:20260421` through `xnat2bids`, Neurodesk `vnmd/musclemap_1.3.45:20260701`, and Neurodesk `vnmd/spinalcordtoolbox_7.3.0:20260605`. Build the local fMRIPrep image with `scripts/build-fmriprep-image.sh` before installing the commands. fMRIPrep 25.2.5 performs an unconditional FreeSurfer license validation even with `--fs-no-reconall`; the build fetches the public license embedded in Neurodesk's FreeSurfer recipe at pinned commit `2a7fc6cfb64afc09f229dea3c64102f1cc68a7a4`, checks its SHA-256, and bakes it into the local image without storing the license text in this repository. MRIQC, fMRIPrep, and ASLPrep wrappers must already have scan-level `NIFTI` resources and `BIDS` JSON sidecars. QSMxT (`qsmxt-session`, command version `8.3.2-ais.2`) no longer uses the `xnat2bids-setup` step: it mounts the session's DICOM archive directly at `/input` and converts to BIDS inside the container (`qsmxt.cli.dicom_sort` — invoked as `python -c "from qsmxt.cli.dicom_sort import main; main()"` since the module has no `__main__` guard — then `dicom-convert --auto_yes`) before running `qsmxt --premade gre --do_qsm`, so no pre-existing `NIFTI`/`BIDS` scan resources are required. It relies on QSMxT's own heuristics to identify multi-echo GRE `part-mag`/`part-phase` (`MEGRE`) QSM series and does not depend on the site/project BIDS map. Because the session DICOMs are object-store symlinks, the read-only `/data/xnat/object-store` bind (below) must be present for the direct mount to resolve. The patched Container Service plugin jar adds a read-only `/data/xnat/object-store` Docker bind mount when that path exists, so scan-level dcm2niix, MuscleMap, and Spinal Cord Toolbox can follow absolute symlinks into the object store without rehydrating files; keep `plugins/patches/container-service-object-store-bind.patch` aligned with the jar. Scan-level MuscleMap and Spinal Cord Toolbox process the first `.nii` or `.nii.gz` file in lexical order. Each now exposes a single scan wrapper that always converts the scan's `DICOM` resource to NIfTI at launch time rather than assuming a pre-existing `NIFTI` resource: `spinalcordtoolbox-deepseg-dicom-scan` (label "Spinal Cord Toolbox") and `musclemap-dicom-scan` (label "MuscleMap"). Both use the `docker-setup` command in `container-service/commands/dcm2niix-setup.json` (image `xnat/dcm2niix:1.6`) via `via-setup-command`, so dcm2niix converts the `DICOM` resource into the tool's input mount at launch and no persistent `NIFTI` resource is created. The earlier NIfTI-only wrappers (`spinalcordtoolbox-deepseg-scan`, `musclemap-scan`) and the BIDS/`xnat2bids-setup` session wrapper (`musclemap-session`) were removed. Note the internal command names stay `spinalcordtoolbox-deepseg` and `musclemap-nifti` even though only the DICOM wrapper remains. There is likewise exactly one `dcm2niix` command (`container-service/commands/dcm2niix-scan.json`, version `1.6-ais.2`) with the scan-level `dcm2niix-scan` wrapper and whole-session `dcm2niix-session` wrapper; the session wrapper recursively converts every DICOM series and stores the outputs in a session-level `NIFTI` resource. There is also one `xnat2bids` setup command (version `1.4`); older stray duplicates once coexisted (`dcm2niix` v1.5 made the per-scan menu show `dcm2niix` twice, and a second `xnat2bids` v1.3 made the `via-setup-command: xnat/xnat2bids-setup:1.4:xnat2bids` reference ambiguous). If a duplicate command name reappears (`GET /xapi/commands`), delete the older/non-repo version with `DELETE /xapi/commands/<id>`. Keep `dcm2niix-setup` uploaded/public in the installer alongside `xnat2bids-setup`; setup commands have no XNAT wrapper to enable. DICOM-to-BIDS depends on a site or project BIDS map at `/data/config/bids/bidsmap` or `/data/projects/<project>/config/bids/bidsmap`. The installer enables wrappers site-wide and for existing projects; `manifests/container-service-project-sync.yaml` keeps wrappers enabled for future projects.
- Container launch status: the Container Service jar is also patched with `plugins/patches/container-service-single-launch-tracking.patch` (JS resources inside the jar) so single container launches post to the `bulklaunch` endpoint, get a `bulk-launch-id`, and show live progress in XNAT's Processing activity panel — the same tracking bulk launches always had. The patch also adds `XNAT.plugin.containerService.viewContainerLogs` (site-wide container log viewer dialog) and a fallback `XNAT.plugin.batchLaunch.viewWorkflowDetails` (the batch-launch plugin that normally defines it is not installed). The Active Processes banner on report pages is overridden via `templates/screens/workflow_alert.vm`, written into Tomcat at pod init by the `xnat-web-init` ConfigMap (`manifests/configmap.yaml`); it adds `[View Logs]` links for container workflows (the workflow `comments` field holds the Docker container hash, which `/xapi/containers/{id}/logs/{file}` accepts directly). When a workflow has no linked container, the fallback fetches `/data/workflows/{id}` and distinguishes still-queued runs from `Failed (Staging)` runs (Docker create failed before a container existed, so there are no logs) and shows the workflow `details`. Log access is enforced server-side: the launching user, project owners, and admins. Keep both jar patches applied when rebuilding the fat jar, and remember browsers may cache the old launcher JS after a jar update (hard refresh). Site SMTP is unconfigured (`localhost:25`; GCP blocks port-25 egress), so email notifications for container completion are deliberately not implemented.
- Docker create timeout: `DockerControlApi` builds the docker-java/OkHttp client with a hardcoded 4.5 s `readTimeout`, which makes `POST /containers/create` fail with `SocketTimeoutException` → workflow `Failed (Staging)` when a large Neurodesk image (spinalcordtoolbox, musclemap, fmriprep, qsmxt) is still pulling/extracting on a busy host, leaving an orphaned `Created` container the Container Service never tracks (`docker rm` it, then re-run). The same patch file raises that constant to **300000 ms (5 min)**. It was originally an in-place `sipush` swap to 32000 ms (`11 11 94` → `11 7D 00`), but a ~38 GB image (spinalcordtoolbox 7.3.0) still tripped 32 s while extracting, and `sipush` caps at 32767 ms; the current patch instead appends a new `Integer` constant to the class constant pool and swaps `sipush 32000` for `ldc_w` (both 3 bytes, so no bytecode offsets / StackMapTable / Code length shift — no source rebuild needed). Re-apply and verify per the notes at the bottom of `plugins/patches/container-service-single-launch-tracking.patch`: there is no `javap` on the host, so validate by re-parsing the class (constant_pool_count == old+1, appended `Integer==300000`, instruction at the readTimeout site == `13 08 55`) and confirm the plugin loads (no `VerifyError`/`ClassFormatError` in the `xnat-web` log) and `GET /xapi/docker/server` returns `"ping":true` after the restart. Pre-pulling the big images (or setting the Docker server config to pull on init; `pull-images-on-xnat-init` is currently `false`) also avoids racing create against a fresh pull.
- Container tracking stuck at `Created` / event poller poisoned by future timestamp: the Container Service tracks container start/die via a Docker event poller that runs every ~10 s and calls `GET /events?since=<last_event_check_time>&until=<now>`. The `since` comes from `xhbm_docker_server_entity.last_event_check_time`, stored as a **naive** timestamp in the XNAT application timezone. If that column ever holds a value in the future relative to real UTC, Docker rejects every poll with `Status 400: "since time (…) cannot be after until time (…)"` (logged on the `docker-java-stream-*` thread as `ERROR ... Error during callback`), the poller never advances, and **every** container launched afterward runs to completion on the host but is never finalized — it stays `Created`, its workflow stays `Created` (Active Processes banner never clears), and its outputs are never uploaded. `GET /xapi/docker/server` still returns `"ping":true`, so the platform-monitor Docker check does not catch this. This happened on 2026-07-10 when the app timezone changed `Australia/Brisbane → America/Los_Angeles`: container 19's event rows in `xhbm_container_entity_history` had been written as Brisbane-local wall-clock and were then read back as LA-local, so `last_event_check_time` was poisoned ~17 h into the future (`since` landed ~14 h ahead of `until`). Recovery: (1) rescue any already-finished-but-stuck run with `POST /xapi/containers/<id>/finalize` (admin) — this uploads its outputs and closes the workflow; (2) reset the checkpoint in postgres (pod `xnat-web-postgresql-0`, db/user `xnat`, password in `xnat-web-postgresql` secret key `password`, `psql` at `/opt/bitnami/postgresql/bin/psql`): `UPDATE xhbm_docker_server_entity SET last_event_check_time = (now() at time zone 'America/Los_Angeles') - interval '10 minutes';` — the timezone in that expression must match the app timezone; (3) **restart `xnat-web`** — the entity is cached in the JVM and only reloaded from the DB at startup, so a DB update alone does not take effect. Verify: no new `cannot be after` lines in the `xnat-web` log and `last_event_check_time` now trails real time by ~one poll interval (a few seconds), which only happens on successful (non-400) polls.
- `manifests/project-owner-sync.yaml` keeps `brosnan`, `edge-uploader`, and `sciget` in the XNAT `Owners` group for every current and future project. The `edge-uploader` ownership is required because the `xnat-upload` alias token inherits that user's project permissions. The sync runs every 15 minutes using the admin credentials from `xnat-archiver-creds`; apply it with `sudo kubectl apply -f manifests/project-owner-sync.yaml` and trigger a manual job after changes to verify. The same sync also grants group-derived ownership: ais-edge routes DICOMs with PatientID `<subject>@<group>/<project>`, the group survives in each session's `dcmPatientId`, and when the group name matches an enabled XNAT user (e.g. `polimeni`), that user is made an Owner of every project holding that group's sessions. Groups without a matching XNAT user are skipped and logged; creating the user later activates ownership on the next sync. Note `/xapi/users/<name>` returns HTTP 500 (not 404) for unknown users — check membership against the `/xapi/users` list instead.
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

If XNAT shows many failed `Pulled Data from DICOM` workflows after ais-edge uploads, check the `xnat-upload/xnat-ingest-upload` deployment. Catalog-only `DICOM` resources in the archive make XNAT's `pullDataFromHeaders=true` endpoint fail with `Unable to locate DICOM or ECAT files`; the ingest uploader should skip that header-pull step unless local DICOM objects are actually present. Another failure mode is `Modification of scan modality (xnat:mrScanData to xnat:otherDicomScanData) not supported`: a non-MR-image DICOM was created as an MR scan before header extraction. The live guarded patch `ais-devstack/non-image-dicom-scan-modality=xnat-ingest-pr-secondary-capture-other-dicom-v2` maps both Presentation State objects (`Modality=PR`, such as Siemens `*_PR` series) and Multi-frame Grayscale Word Secondary Capture objects (`SOPClassUID=1.2.840.10008.5.1.4.1.1.7.3`) to XNATPy's `OtherDicomScanData` at scan creation. The latter can misleadingly carry `Modality=MR` and `ImageType=ORIGINAL\PRIMARY`, as the Siemens `Inline_VF_Results` scans 18/23/28 did on `XNAT_E00400` on 2026-08-28, so modality and ImageType alone are insufficient. To repair an existing session, first verify the retained `uploaded/` object and its DICOM header, delete only the affected scan with `removeFiles=true`, recreate it as `xnat:otherDicomScanData`, re-upload the retained DICOM, and rerun `pullDataFromHeaders=true`. XNAT then moves these objects from `DICOM/` into the scan's `secondary/` directory; that is the expected final location even though the registered resource label remains `DICOM`. A failed earlier pull can leave a pre-existing secondary copy that collides with the repaired DICOM (`FileAlreadyExistsException`): verify that old copy byte-for-byte against the retained source and move it completely outside the session archive before retrying. Merely renaming it under `SCANS/<id>/` is insufficient because XNAT's `CatalogBuilder` recursively inspects every directory there. Require a clean `Complete` workflow, the correct `xnat:otherDicomScanData` type and metadata, and source-matching files in the final `secondary/` directory. Active stale failures can be dismissed by marking `wrk_workflowdata.status` as `Failed (Dismissed)` for `pipeline_name='Pulled Data from DICOM'`.

Use `scripts/purge-xnat-workflows.sh` for workflow table cleanup. It defaults to a dry-run, matches only `Complete` workflows older than 30 days, compares `launch_time` in the XNAT application timezone, and deletes paired `wrk_workflowdata_meta_data` rows only after deleting the workflow rows that referenced them. For the common high-volume audit noise from bulk archive operations, review a dry-run such as `./scripts/purge-xnat-workflows.sh --older-than-days 1 --pipeline "Uploaded File" --pipeline "Catalog(s) Refreshed"` before adding `--execute`. Do not purge `Running` or recent container-service workflow rows.

`manifests/xnat-project-provisioner.yaml` runs the `xnat-project-provisioner` CronJob in `xnat-upload` every minute, ahead of xnat-ingest's 5-minute staged quiet window. It scans the ready/staged SeaweedFS prefixes and creates any missing, syntactically valid XNAT project with the rotating `xnat-credentials` alias (the underlying `edge-uploader` is allowed to create projects and becomes an Owner, so no admin credentials are copied into `xnat-upload`). It ensures `brosnan`, `edge-uploader`, and `sciget` remain Owners and, for PatientID routes of the form `<subject>@<group>/<project>`, requests and verifies the matching group user as an Owner. XNAT returns HTTP 200 even when adding a nonexistent user, so the job verifies the project users list; a missing group user is logged as deferred and the existing `project-owner-sync` adds it after that user exists. XNAT project IDs, names, and `secondary_ID` values share uniqueness constraints, but XNATPy indexes uploads only by primary ID/label. The provisioner therefore resolves a unique case-insensitive match across those three fields and atomically filer-renames an aliased staged session to the canonical primary-ID prefix before ingestion (for example, `Kelley_dev.*` routes to project `DK7T`, whose `secondary_ID` is `Kelley_dev`). It refuses ambiguous aliases or a staged/PatientID route mismatch; the filer rename preserves object mtimes and copies no bytes. XNAT permanently reserves deleted project IDs: a staged route targeting one fails provisioning with HTTP 403 and must be corrected to a new project ID rather than silently recreated (this was the cause of the retained `dicomtest` failures on 2026-07-24). The staged prefix is the provisioning approval boundary: automatic edge labeling still obeys `AIS_EDGE_AUTO_IMPORT_ALLOWED_PROJECTS`, while an explicit/manual `xnat-ingest-ready` label intentionally admits a project outside that automatic allowlist. Apply with `sudo kubectl apply -f manifests/xnat-project-provisioner.yaml`; manual trigger: `sudo kubectl -n xnat-upload create job --from=cronjob/xnat-project-provisioner xnat-project-provisioner-manual-$(date +%s)`.

The `xnat-ingest-upload` deployment also hot-patches `xnat-ingest` idempotency (`ais-devstack/empty-resource-hotfix=xnat-ingest-empty-resources-not-uploaded-v4`) so existing empty or partial XNAT resources do not count as uploaded. It compares staged resource manifest file names with XNAT catalog entries before skipping an upload. If an upload is interrupted and leaves truncated files outside the XNAT catalog, delete the partial XNAT experiment/resource with `removeFiles=true` and let the staged data re-upload; do not move the staged prefix to `uploaded/` until XNAT file counts match the staged file count.

The in-cluster `xnat-ingest-upload` deployment is also hot-patched with `ais-devstack/scan-uid-backfill=xnat-ingest-backfill-scan-uids-v4`. The hook runs before staged sessions are archived, including immediately after both successful and failed upload attempts so a session created during the current attempt is backfilled before its staged source moves to `uploaded/`. It resolves staged session labels to `XNAT_E...` experiment IDs through the project/subject experiment listing (direct `/data/experiments/<label>/...` calls can return HTTP 500), waits until XNAT file counts match staged file counts, requests scan columns as `ID,UID`, range-reads one DICOM header for each scan whose UID is blank, extracts top-level `SeriesInstanceUID`, and writes `xnat:mrScanData/UID`. Keep equivalent behavior if the deployment is rebuilt; otherwise a newly created project/session can archive successfully while leaving OHIF with zero instances.

The rsl60 edge `xnat-ingest-sort` deployment keeps `--wait-period 1800` and `AIS_EDGE_AUTO_IMPORT_WAIT_PERIOD=1800`; its `xnat-ingest-sort-wrapper` ConfigMap auto-labeler waits for an unchanged Orthanc study snapshot before applying `xnat-ingest-ready`. It also persists the series/instance-count snapshot of every `xnat-ingest-skip` study. If more DICOMs later appear under the same Orthanc study (for example, a participant returns to the scanner), the changed snapshot must remain stable for the same 30-minute quiet period before the auto-labeler removes `xnat-ingest-skip` and restores `xnat-ingest-ready`. The next sorter pass merges that study into the existing staged/XNAT session; after the sorter restores `xnat-ingest-skip`, the new snapshot becomes the uploaded baseline. On first deployment, historical skipped studies are baselined without re-importing them. Its auto-label heartbeat includes `reimport_pending`, `reimport_ready`, and the most recent state-reset event. The platform monitor alerts when a stable change remains pending for more than 45 minutes, a ready re-import remains unconfirmed for more than 10 minutes, or the state file reset within the last 24 hours. Keep the sort Deployment strategy as `Recreate`: overlapping old/new sort pods share the Orthanc labels, staging hostPath, and state file and can clobber the baseline during a rolling update. Preserve this state machine and the durable source in `../ais-edge/manifests/02-edge/xnat-ingest.yaml.tpl` when rebuilding so slow OpenRecon/derived series are not staged before the study is complete and appended acquisitions are not missed.

The rsl60 Samba uploader's static `AIS_EDGE_SAMBA_UPLOAD_ALLOWED_PROJECTS` is extended dynamically from routed Orthanc DICOM PatientIDs (`<subject>@<group>/<project>`). The edge sorter discovers projects with `GET /studies?expand`, persists the accumulated set at `/data/staging/__metadata__/samba-dicom-projects.json`, and allows matching `/samba-xnat-upload/<group>/<project>/<subject>/` folders. This ensures projects admitted/auto-created through DICOM ingestion also accept auxiliary Samba files without manually extending the static list. If Orthanc is unavailable, only the persisted/static projects are accepted; unrelated Samba project names remain blocked.

The external Orthanc on rsl60 must keep `OverwriteInstances: true` in `/etc/orthanc/orthanc.json` (enabled 2026-08-06; a timestamped sibling backup was retained). If an operator aborts a scanner send, corrects the routed PatientID, and resends the same acquisition, scanners commonly reuse the SOP Instance UIDs. With Orthanc's default `false`, the first copies win and the corrected resend is silently discarded, so the original scanner-generated PatientID is later routed to `misc`. After any Orthanc config rebuild, verify this setting and the `orthanc` service/API. The edge health alerts described under platform-monitor report fallback DICOM routing and raw Samba folders blocked because the intended routed project was never learned.

The management `xnat-ingest-upload` deployment applies guarded startup patches to the deployed xnat-ingest/XNATPy libraries. They pin each loaded file-set's path/checksum root to its manifest resource directory (otherwise `FileSet.parent` collapses a sole common top-level folder and produces `Checksum keys do not match`), create `dest.parent` before hard-linking nested resource files into the temporary `.RESOURCE-upload` tree, ignore directory entries in XNATPy's `per_file` iterator, disable the label-only `SessionListing.all_uploaded` fast path (resource-label presence does not prove any files arrived), resume an existing resource whose remote checksums differ from the staged manifest (uploads use overwrite, followed by the normal full checksum comparison), and map DICOM Presentation State modality `PR` plus Multi-frame Grayscale Word Secondary Capture SOP class `1.2.840.10008.5.1.4.1.1.7.3` to `OtherDicomScanData` instead of defaulting them to the parent session's MR scan type. When site-wide XNAT checksums are disabled, completion is instead decided from the complete set of URI-relative paths and exact file sizes; this both preserves nested paths and prevents a completed large resource from being uploaded again. The importer calls `pullDataFromHeaders` only for sessions that actually contain a `DICOM` resource, so XNAT never tries to parse multi-GB scanner raw files as DICOM. Preserve these patches until the deployed image contains the upstream equivalents. Without them, a Samba resource containing subdirectories can fail after a complete download with `FileNotFoundError`, `The path points to a non-file object`, or `Checksum keys do not match`, then be skipped forever because its partial resource label exists; the staged S3 prefix remains for retry, while a PR or Secondary Capture series can produce a failed `Pulled Data from DICOM` workflow and an incorrectly typed scan. Every patch is exact-match/idempotent and deliberately fails pod startup if the image source changes instead of silently running unpatched. The upload command also selects `--method per_file generic/file-set`: scanner `.dat` files are effectively incompressible, and the default `tgz_file` needlessly builds a huge single-CPU temporary archive before upload. `per_file` avoids that archive and preserves nested relative paths; these raw sessions contain only tens of files, so per-file request overhead is acceptable.

`manifests/xnat-build-cleanup.yaml` runs the `xnat-build-cleanup` CronJob in `ais-xnat` daily at 06:30 UTC. Container Service does not remove `/data/xnat/build/<uuid>` scratch workspaces after every terminal run, so they otherwise retain converted BIDS trees and tool work directories indefinitely. The cleanup reuses one admin JSESSION, fetches every Container Service record before changing the filesystem, and removes a UUID workspace only when it is referenced exclusively by terminal records (`Complete`, `Killed`, or `Failed*`) and its newest filesystem mtime is older than `RETENTION_HOURS` (default 24). It fails closed when any container detail cannot be loaded, retains active, young, unreferenced, non-UUID, and symlink entries, and mounts only the `pv-xnat-build` PVC. Manual trigger: `sudo kubectl -n ais-xnat create job --from=cronjob/xnat-build-cleanup xnat-build-cleanup-manual-$(date +%s)`. For a live dry-run, temporarily apply `DRY_RUN=1` to the CronJob template, run a one-off job, then restore the manifest's `DRY_RUN=0`; a Job pod template is immutable after creation.

`manifests/docker-image-prune.yaml` runs the `docker-image-prune` CronJob (ais-xnat, daily 07:00 UTC, after build cleanup). Container Service pulls its images through the host Docker daemon and nothing else cleans that storage (it shares the boot volume), so image updates would leave dangling layers behind indefinitely. The job talks to the Docker Engine API over `/var/run/docker.sock` with stdlib Python (no docker CLI) and prunes only dangling (untagged) images plus build cache unused for `BUILD_CACHE_UNTIL` (default 168h). It never removes tagged images — pre-pulled Container Service images (the multi-GB Neurodesk ones that otherwise trip the Docker-create timeout on first launch) must stay — and never touches containers, since removing a Container Service `Created` container could race an in-flight launch. `DRY_RUN=1` on the CronJob template lists without pruning. Manual trigger: `sudo kubectl -n ais-xnat create job --from=cronjob/docker-image-prune docker-image-prune-manual-$(date +%s)`.

### SeaweedFS ingest bucket lifecycle

The live SeaweedFS Deployment is pinned to `chrislusf/seaweedfs:4.00` (upgraded from 3.99 on 2026-07-27 for the S3 conditional-read/`If-Match` fix). Release 4.00 runs as a non-root user by default, but the established `/data/seaweedfs` hostPath tree is root-owned, so keep `securityContext.runAsUser: 0` and `runAsGroup: 0` on the `seaweedfs` container unless the complete tree is deliberately migrated and verified under a different UID/GID. Without that compatibility setting the pod exits before opening the store with `raft: Initialization error: open /data/m9333/log: permission denied`. The Deployment manifest remains live-managed outside this repo; keep the matching maintenance-tool image in `manifests/seaweedfs-vacuum.yaml` pinned to 4.00. The 3.99 failure presented as `S3DownloadFailedError`/HTTP 412 for single-PUT objects larger than SeaweedFS's 4 MiB internal chunk size: list/HEAD returned the full-file MD5 while the S3 conditional-read path compared a chunk-derived ETag. After an upgrade, verify an affected object with `GetObject(IfMatch=<listed ETag>)` and confirm the retained `staged/` prefix completes its XNAT upload, scan-UID backfill, and metadata-only move to `uploaded/`.

Since 2026-07-24 no ingested byte is copied inside the bucket anymore; every prefix transition is a SeaweedFS filer metadata-only rename (`POST http://seaweedfs.seaweedfs.svc.cluster.local:8888/<dst>?mv.from=<dst-encoded-src>` — moves whole directories, creates missing destination parents, returns 204; the filer HTTP port 8888 is exposed on the `seaweedfs` Service). The flow: the edge `s3-uploader` runs a single `mc mirror` of each session into `incoming/<edge>/<session>/` and then publishes a tiny `.upload_complete` marker object via `mc pipe` (it no longer does a second `incoming/ → staged/` mirror); the central `xnat-ingest-upload` wrapper's `promote_incoming_sessions` step (each ~60s loop, before import/archive) moves marker-completed incoming sessions to `staged/<session>` with one filer rename and then sweeps the marker out of `staged/` (the marker travels with the directory move; the sweep also self-heals a crash between move and sweep — the marker must never survive into an import, or the archive step's file-count comparison goes off by one). If `staged/<session>` already exists (re-upload of an appended session) it merges file-by-file, still metadata-only. Object mtimes survive the renames, so the 300 s quiet windows still measure real upload times. The wrapper then archives verified staged sessions to `uploaded/<stamp>/<session>/` by filer rename — except when the session's GCS `.backup_complete` marker (checked through the wrapper's own `/object-store` FUSE hostPath bind) is newer than the newest staged object, in which case the staged copy is already a redundant same-disk replica of the GCS backup and is deleted outright with no `uploaded/` copy. The wrapper deployment is live-managed (annotation `ais-devstack/ingest-fsmv`), not in this repo. `manifests/ingest-uploaded-retention.yaml` runs daily at 4am (after the 2am backup): it deletes `uploaded/` copies older than 7 days whose session has a GCS `.backup_complete` marker (checked through the object-store FUSE hostPath) and clears stale `.uploads` multipart debris; copies without a marker are kept and reported. When debugging bucket usage, note the SeaweedFS filer double-counts nothing but `weed shell` `fs.du` returns 0 for paths given with a trailing slash — use `fs.du /buckets/ingest-bucket` (no trailing slash). Filer-level deletes only mark needles; timed-out S3 copy attempts can additionally leave volume needles that are not referenced anywhere in the single filer's namespace and therefore do not appear in `fs.du`. Disk is actually freed by `manifests/seaweedfs-vacuum.yaml` (`seaweedfs-vacuum` CronJob, seaweedfs namespace, four times daily at 05/11/17/23 UTC — the 5am slot stays an hour after retention — so peak dead-needle space is bounded to hours of churn, not a day). Before selecting volumes, the job scopes `volume.fsck -reallyDeleteFromVolume` to the writable volume IDs and uses `SEAWEEDFS_ORPHAN_CUTOFF_TIME_AGO` (default 24h) to mark only old unreferenced needles deleted; never run this against a SeaweedFS cluster served by multiple independent filers. Read-only volumes are logged and excluded from both orphan purging and vacuum selection because SeaweedFS 3.99's forced purge/compact path can corrupt its own index accounting for them. It then selects writable volumes from `volume.list` with ≥64 MiB garbage or ≥25% garbage ratio (`VACUUM_MIN_DELETED_MB` / `VACUUM_MIN_RATIO`) and vacuums each explicitly by id. `SEAWEEDFS_SKIP_ORPHAN_FSCK=1` exists only for a one-off recovery after an orphan scan has already completed; do not set it on the CronJob. The CronJob disables the master's independent 14–16-minute automatic sweep at the start of every run (the setting is in-memory and resets with the master), then vacuums one volume at a time and requires every selected volume's `compact_revision` to advance before continuing; it retries only the affected volume and does not let Kubernetes replay the complete batch. The live SeaweedFS Deployment, whose manifest is not in this repo, must also keep `-master.garbageThreshold=1.1` in its args: no valid garbage ratio reaches that threshold, so the master's immediate automatic sweep after a pod restart cannot start a compaction before the CronJob disables future sweeps. SeaweedFS 3.99 gotchas baked into that script, equally relevant when vacuuming manually: `weed shell` commands need `lock` first (without it they silently do nothing); the threshold sweep `volume.vacuum -garbageThreshold 0.1` skips near-100%-garbage volumes, so vacuum per `-volumeId`; even with `-volumeId` the default `garbageThreshold` (0.3) still applies and silently skips volumes below it, so pass `-garbageThreshold 0.001` explicitly; and `weed shell` bootstraps over master gRPC at port+10000, so the `seaweedfs` Service must keep exposing 19333 (master-grpc) and 18888 (filer-grpc) — added 2026-07-11 by live patch; the seaweedfs Deployment/Service manifests are not in this repo — or the shell hangs on `WaitUntilConnected`. SeaweedFS 4.00 can briefly retain the 10-second admin lease when its lock-renew goroutine races an `unlock`; a following shell prints `lock: rpc error: ... already locked by ...` while blocking until that lease expires. The vacuum job ignores only that exact acquisition-retry diagnostic after the requested command completes and still fails on every other fsck/purge error. Failure mode seen 2026-07-11: a hung vacuum goroutine leaves the master's separate in-memory vacuum guard held forever, so every `volume.vacuum` (including the master's own periodic sweep) becomes a silent no-op logging `Vacuum is already running` in the master log while `weed shell` still exits 0. The CronJob fails on the first exact volume whose compact revision does not advance after its bounded retries so the platform monitor alerts; recovery is `sudo kubectl -n seaweedfs rollout restart deploy/seaweedfs` (check the edge s3-uploader and central xnat-ingest-upload are idle first). Manual trigger: `sudo kubectl -n seaweedfs create job --from=cronjob/seaweedfs-vacuum seaweedfs-vacuum-manual-$(date +%s)`. The old copy+delete archive step left empty directory skeletons under `staged/` and `incoming/` that made the wrapper churn; the filer-rename flow moves the directory itself so no skeletons are produced, and the historical ones (346) were removed on 2026-07-24. Skeletons are safe to delete whenever a subtree has no file entries.

SeaweedFS volumes 9 and 10 are historical `ingest-bucket` volumes that remain intentionally read-only. On 2026-07-24 `volume.fsck` found 271,969,870 bytes of unreferenced content across them, but both normal and `-forcePurging` modes left those orphan needles in place; attempting to compact volume 10 failed with `unexpected new data size ... does not match size of content minus deleted`. They also retain only ~0.8 MiB of ordinary deleted-byte counters. Do not make or vacuum these volumes automatically: they also contain referenced live files, and the unreclaimable ~0.27 GiB is negligible. The daily job excludes them through their `read_only:true` state.

Update 2026-08-06: the preceding statement that the uploader wrapper is
live-managed is obsolete. Its durable source is now
`../ais-edge/manifests/01-management/xnat-upload.yaml.tpl`, stamped with the
`ais-devstack/ingest-fsmv` annotation; redeploy from that template.

A successful SeaweedFS vacuum commit can take several volume heartbeats to
appear in `volume.list` (observed 2026-07-15). The CronJob's post-vacuum check
therefore retries for up to about one minute; an immediate one-shot check can
false-fail even though the compact revisions advance moments later.

On 2026-08-06 the central `xnat-ingest-upload` wrapper's inline
`sync_xnat_project_admins` loop exhausted XNAT's 1,000-session limit in about
75 minutes: it made one HTTP-Basic request per project every minute, and each
request minted an eight-hour session. Keep the durable implementation in
`../ais-edge/manifests/01-management/xnat-upload.yaml.tpl` on the one-JSESSION
pattern (`POST /data/JSESSION` once, cookie for all project requests, `DELETE`
in `finally`). The platform monitor likewise shares one JSESSION across all of
its authenticated XNAT checks and emits a single actionable `xnat-auth` alert
if login is rejected with 401. Recovery still requires an `xnat-web` restart
because Tomcat holds the exhausted session registry in memory.

The controlled vacuum orders selected volumes by deleted bytes, largest first,
so an emergency run restores node headroom as quickly as possible. Keep the
SeaweedFS deployment at `system-cluster-critical` priority with an `Exists`
toleration: otherwise kubelet can evict the storage process during disk
pressure, preventing the vacuum that would resolve the pressure. Never move
data between bucket prefixes with S3 `CopyObject`; the client can time out
after SeaweedFS has already written a partial destination, and retries then
consume the node with duplicate garbage. The wrapper's promote and archive
steps now use the filer's metadata-only rename for exactly this reason; do the
same for any manual prefix move (`weed shell` `fs.mv`, or the filer HTTP
`?mv.from=` call) and verify the destination logical size afterwards.

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
central `xnat-upload/xnat-ingest-upload` logs. The edge uploader mirrors to
`incoming/edge-rsl60/...` and publishes a `.upload_complete` marker; the central
uploader promotes the session to `staged/...` with a filer metadata move and
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

The `.backup_complete` marker in GCS is not trusted on its own: sessions can gain scans after their first backup (appended OpenRecon/derived series). When any regular local file in a session is newer than the marker object's creation time, the archiver logs `STALE`, removes the marker, and re-syncs the session incrementally before offloading again. The archiver uses `gcloud storage` (not the deprecated bundled `gsutil`); local `gcloud storage rsync` explicitly uses `--ignore-symlinks` so already-offloaded symlinks are never followed back through the FUSE mount. Many historical sessions were offloaded against the old REST-ZIP bucket layout (`sessions/<project>/<label>/<label>/scans/...`); ~150k live archive symlinks point at those objects, so never delete old-layout prefixes from the bucket. The archiver script is baked into the `xnat-gcs-archiver:latest` image — after editing `archiver/xnat-archive-to-gcs.sh`, rebuild with `docker build -t xnat-gcs-archiver:latest archiver/` and `docker save xnat-gcs-archiver:latest | sudo k3s ctr images import -`.

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

`manifests/platform-monitor.yaml` runs the `platform-monitor` CronJob (ais-xnat namespace, every 15 minutes) which emails `mail.neurodesk@gmail.com` via Gmail SMTP. It checks: node disk usage (warn 80% / crit 90%), unhealthy pods and container restarts in the core namespaces, failed k8s Jobs and stale CronJobs (no success within ~1.5× their schedule period; terminal Job-owned pods are ignored by the generic pod check because their owning Jobs/CronJobs provide the authoritative failure and recovery state; CronJob-owned job failures are keyed as a `cronjob-failing:<ns>/<name>` issue — alert once, re-alert per `REALERT_HOURS` (24h), RECOVERED when the latest run succeeds — instead of a per-job event, since a failing 15-min CronJob would otherwise email every run; only standalone Jobs still produce one-time per-job events), XNAT reachability (in-cluster service and public URL), public TLS certificate expiry (<14 days), Container Service Docker ping, XNAT active server-side session counts for admin/edge-uploader (warn above `XNAT_SESSION_WARN`, default 500 — catches JSESSION leaks before the `concurrentMaxSessions` 401 lockout; note `GET /xapi/users/active/<user>` returns HTTP 304, not an empty list, when the user has zero active sessions — the check treats 304 as 0), newly failed XNAT workflows (`wrk_workflowdata`, dismissed excluded), pending user-initiated project access requests (`xs_par_table` rows with `approved IS NULL` and `user_id IS NOT NULL` — these re-alert daily until approved/denied), edge ingest health objects under `ingest-bucket/health/<edge>/` (missing/stale heartbeat, raw folders blocked by the Samba project allow-list, raw staging failures, DICOM studies blocked by project policy, unroutable DICOM studies headed to the fallback project, delayed re-import states, and recent auto-label state resets), ingest `staged/`/`incoming/` prefixes older than 2h (stuck uploader; `incoming/<edge>/<session>` is aged at the session level, never by the long-lived edge directory), and nightly Postgres dump freshness (`db-backup` issue when the newest `db-backups/xnat-*.sql.gz` in GCS is older than `DB_BACKUP_MAX_AGE_HOURS`, default 30, or suspiciously small — read through a dedicated hostPath bind of the object-store FUSE mount at `/object-store`, since the gcsfuse submount does not propagate through the recursive `/host` bind). Edge sorters atomically write `edge-ingest-auto-label-health.json` and `edge-ingest-samba-health.json` under staging metadata; the edge S3 uploader republishes them every loop. `EXPECTED_EDGES` defaults to `edge-rsl60` and `EDGE_HEALTH_MAX_AGE_MINUTES` defaults to 10, so loss of the sorter/publication path alerts before data can remain silently stranded. Re-import alert defaults are 45 minutes for a stable pending change, 10 minutes for a ready study without sorter confirmation, and 24 hours of visibility after a state reset. A fallback-routing alert explicitly calls out the aborted-send/corrected-resend case where reused SOP Instance UIDs can make Orthanc retain the first scanner-generated PatientID unless `OverwriteInstances` is enabled. XNAT 1.9.3's project Access tab fetches all PAR rows but its `parManager.js` retains only rows with `email` populated; user-initiated requests instead have `user_id` populated and `email` NULL, so they are invisible there. Each monitor alert and digest entry therefore includes XNAT's supported legacy approval form URL, `/app/template/RequestProjectAccessForm.vm/project/<project>/id/<user_id>/access_level/<level>`; sign in before following it. The form's `ProcessAccessRequest` action updates the matching PAR and project group together.

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
