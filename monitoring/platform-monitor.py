#!/usr/bin/env python3
"""XNAT platform monitor.

Runs as a k8s CronJob every 15 minutes. Checks platform health, emails
alerts for NEW problems (with recovery notices and periodic re-alerts for
ongoing ones), and sends a daily digest that doubles as a dead-man's
switch: if the digest stops arriving, the monitor itself is broken.

Checks:
  - disk usage on the node (via read-only hostPath /host)
  - unhealthy pods and container restarts in monitored namespaces
  - failed k8s Jobs and stale CronJobs (no recent successful run)
  - XNAT web reachable (in-cluster service and public URL)
  - public TLS certificate expiry
  - Container Service Docker daemon ping
  - XNAT-to-JupyterHub service authentication and launch policy
  - stale JupyterHub named servers and unhealthy Jupyter home volumes
  - newly failed XNAT workflows (Postgres wrk_workflowdata)
  - pending project access requests (Postgres xs_par_table)
  - edge ingest heartbeats, blocked raw uploads, and fallback DICOM routing
  - stuck ingest staging prefixes (SeaweedFS filer)
  - nightly Postgres dump freshness in GCS (via the object-store FUSE mount)

State lives in STATE_FILE so alerts fire once per problem, not per run.
"""

import base64
import json
import os
import smtplib
import socket
import ssl
import sys
import traceback
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from zoneinfo import ZoneInfo

import pg8000.native

# ── Configuration ────────────────────────────────────────────────────

def env(name, default=None):
    value = os.environ.get(name, default)
    if value is None:
        raise SystemExit(f"Missing required environment variable {name}")
    return value

SMTP_HOST = env("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(env("SMTP_PORT", "587"))
SMTP_USER = env("SMTP_USER")
SMTP_PASS = env("SMTP_PASS")
ALERT_TO = env("ALERT_TO", SMTP_USER)
SUBJECT_PREFIX = env("SUBJECT_PREFIX", "[xnat-lucas]")

XNAT_INTERNAL_URL = env("XNAT_INTERNAL_URL", "http://xnat-web.ais-xnat.svc.cluster.local").rstrip("/")
XNAT_PUBLIC_URL = env("XNAT_PUBLIC_URL", "https://xnat-lucas.neurodesk.org").rstrip("/")
XNAT_USER = env("XNAT_USER")
XNAT_PASS = env("XNAT_PASS")

PGHOST = env("PGHOST", "xnat-web-postgresql.ais-xnat.svc.cluster.local")
PGPORT = int(env("PGPORT", "5432"))
PGDATABASE = env("PGDATABASE", "xnat")
PGUSER = env("PGUSER", "xnat")
PGPASSWORD = env("PGPASSWORD")

FILER_URL = env("FILER_URL", "http://seaweedfs.seaweedfs.svc.cluster.local:8888").rstrip("/")
INGEST_BUCKET = env("INGEST_BUCKET", "/buckets/ingest-bucket")
EXPECTED_EDGES = [edge.strip() for edge in env(
    "EXPECTED_EDGES", "edge-rsl60"
).split(",") if edge.strip()]
EDGE_HEALTH_MAX_AGE_MINUTES = int(env("EDGE_HEALTH_MAX_AGE_MINUTES", "10"))

K8S_NAMESPACES = [ns.strip() for ns in env(
    "K8S_NAMESPACES", "ais-xnat,xnat-upload,jupyter,seaweedfs,ingress-nginx,cert-manager"
).split(",") if ns.strip()]

HOST_ROOT = env("HOST_ROOT", "/host")
DISK_PATHS = [p.strip() for p in env(
    "DISK_PATHS", "/,/srv/xnat-local-storage,/data/seaweedfs"
).split(",") if p.strip()]
DISK_WARN_PCT = float(env("DISK_WARN_PCT", "80"))
DISK_CRIT_PCT = float(env("DISK_CRIT_PCT", "90"))

CERT_WARN_DAYS = int(env("CERT_WARN_DAYS", "14"))
POD_GRACE_MINUTES = int(env("POD_GRACE_MINUTES", "15"))
JUPYTER_STALE_MINUTES = int(env("JUPYTER_STALE_MINUTES", "20"))
STAGED_MAX_AGE_HOURS = int(env("STAGED_MAX_AGE_HOURS", "24"))
REALERT_HOURS = int(env("REALERT_HOURS", "24"))
XNAT_SESSION_WARN = int(env("XNAT_SESSION_WARN", "500"))
XNAT_SESSION_USERS = [
    u.strip() for u in env("XNAT_SESSION_USERS", "admin,edge-uploader").split(",")
    if u.strip()]
WORKFLOW_LOOKBACK_DAYS = int(env("WORKFLOW_LOOKBACK_DAYS", "3"))

DB_BACKUP_DIR = env("DB_BACKUP_DIR", "/object-store/db-backups")
DB_BACKUP_MAX_AGE_HOURS = int(env("DB_BACKUP_MAX_AGE_HOURS", "30"))

STATE_FILE = env("STATE_FILE", "/state/state.json")
DIGEST_HOUR = int(env("DIGEST_HOUR", "8"))
TZ_NAME = env("TZ_NAME", "America/Los_Angeles")
FORCE_DIGEST = os.environ.get("FORCE_DIGEST", "0").lower() in {"1", "true", "yes"}

NOW = datetime.now(timezone.utc)
LOCAL_NOW = NOW.astimezone(ZoneInfo(TZ_NAME))

# ── Results collected by checks ──────────────────────────────────────

issues = {}   # key -> detail text; persistent conditions (get recovery notices)
events = []   # one-time notifications (no recovery tracking)
digest = []   # (section, text) pairs for the daily digest


def add_issue(key, detail):
    issues[key] = detail.strip()


def run_check(name, fn):
    try:
        fn()
    except Exception:
        add_issue(f"check-error:{name}",
                  f"Monitor check '{name}' itself failed:\n"
                  + "".join(traceback.format_exc().splitlines(keepends=True)[-8:]))


def project_access_request_url(project_id, user_id, level):
    """Return XNAT's legacy approval form for a user-initiated PAR."""
    quote = lambda value: urllib.parse.quote(str(value), safe="")
    return (f"{XNAT_PUBLIC_URL}/app/template/RequestProjectAccessForm.vm"
            f"/project/{quote(project_id)}/id/{quote(user_id)}"
            f"/access_level/{quote(level)}")


# ── Helpers ──────────────────────────────────────────────────────────

def http_get(url, headers=None, timeout=30, insecure=False):
    req = urllib.request.Request(url, headers=headers or {})
    ctx = ssl._create_unverified_context() if insecure else None
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        return resp.status, resp.read()


def xnat_auth_header():
    token = base64.b64encode(f"{XNAT_USER}:{XNAT_PASS}".encode()).decode()
    return {"Authorization": f"Basic {token}"}


K8S_API = "https://kubernetes.default.svc"
K8S_TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
K8S_CA_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"


def k8s_get(path):
    with open(K8S_TOKEN_FILE) as fh:
        token = fh.read().strip()
    req = urllib.request.Request(
        f"{K8S_API}{path}", headers={"Authorization": f"Bearer {token}"})
    ctx = ssl.create_default_context(cafile=K8S_CA_FILE)
    with urllib.request.urlopen(req, timeout=30, context=ctx) as resp:
        return json.load(resp)


def parse_k8s_time(value):
    if not value:
        return None
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def parse_iso_time(value):
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def load_state():
    try:
        with open(STATE_FILE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh, indent=1, sort_keys=True)
    os.replace(tmp, STATE_FILE)


state = load_state()
state.setdefault("alerts", {})
state.setdefault("restart_counts", {})
state.setdefault("alerted_jobs", [])
state.setdefault("alerted_workflows", [])

# ── Checks ───────────────────────────────────────────────────────────

def check_disk():
    lines = []
    seen_devices = set()
    for path in DISK_PATHS:
        target = HOST_ROOT.rstrip("/") + path
        try:
            device = os.stat(target).st_dev
            st = os.statvfs(target)
        except OSError as exc:
            add_issue(f"disk-missing:{path}", f"Cannot stat {path} on host: {exc}")
            continue
        if device in seen_devices:
            continue
        seen_devices.add(device)
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        used_pct = 100.0 * (1 - free / total) if total else 0.0
        line = f"{path}: {used_pct:.1f}% used, {free / 1e9:.0f} GB free of {total / 1e9:.0f} GB"
        lines.append(line)
        if used_pct >= DISK_CRIT_PCT:
            add_issue(f"disk-critical:{path}", f"CRITICAL disk usage — {line}")
        elif used_pct >= DISK_WARN_PCT:
            add_issue(f"disk-warning:{path}", f"High disk usage — {line}")
    digest.append(("Disk usage", "\n".join(lines)))


def check_pods():
    restart_counts = {}
    summary = []
    for ns in K8S_NAMESPACES:
        pods = k8s_get(f"/api/v1/namespaces/{ns}/pods").get("items", [])
        running = 0
        for pod in pods:
            name = pod["metadata"]["name"]
            uid = pod["metadata"]["uid"]
            phase = pod.get("status", {}).get("phase")
            created = parse_k8s_time(pod["metadata"].get("creationTimestamp"))
            age = NOW - created if created else timedelta(0)
            if pod["metadata"].get("deletionTimestamp") or phase == "Succeeded":
                continue

            statuses = pod.get("status", {}).get("containerStatuses", [])
            restarts = sum(cs.get("restartCount", 0) for cs in statuses)
            restart_counts[uid] = restarts
            previous = state["restart_counts"].get(uid)
            if previous is not None and restarts > previous:
                reasons = ", ".join(sorted({
                    (cs.get("lastState", {}).get("terminated", {}) or {}).get("reason", "?")
                    for cs in statuses if cs.get("restartCount", 0) > 0}))
                events.append(
                    f"Pod {ns}/{name} restarted ({previous} -> {restarts} restarts, "
                    f"last termination reason: {reasons})")

            if phase == "Running":
                running += 1

            if age < timedelta(minutes=POD_GRACE_MINUTES):
                continue
            if phase == "Failed":
                add_issue(f"pod:{ns}/{name}", f"Pod {ns}/{name} is in phase Failed")
            elif phase == "Pending":
                add_issue(f"pod:{ns}/{name}",
                          f"Pod {ns}/{name} Pending for {age} (scheduling/image/volume problem?)")
            elif phase == "Running":
                not_ready = [
                    f"{cs['name']} ({((cs.get('state', {}).get('waiting') or {}).get('reason')) or 'not ready'})"
                    for cs in statuses if not cs.get("ready")]
                if not_ready:
                    add_issue(f"pod:{ns}/{name}",
                              f"Pod {ns}/{name} Running but containers not ready: {', '.join(not_ready)}")
        summary.append(f"{ns}: {running} running / {len(pods)} pods")
    state["restart_counts"] = restart_counts
    digest.append(("Pods", "\n".join(summary)))


def cron_period_minutes(schedule):
    fields = (schedule or "").split()
    if len(fields) != 5:
        return 24 * 60
    minute, hour = fields[0], fields[1]
    if minute.startswith("*/") and hour == "*":
        return int(minute[2:])
    if hour.startswith("*/"):
        return int(hour[2:]) * 60
    if hour == "*":
        return 60
    return 24 * 60


def job_condition(job, cond_type):
    return any(
        c.get("type") == cond_type and c.get("status") == "True"
        for c in job.get("status", {}).get("conditions", []) or [])


def job_failure_reason(job):
    return "; ".join(
        f"{c.get('reason', '')}: {c.get('message', '')}"
        for c in job.get("status", {}).get("conditions", []) or []
        if c.get("type") == "Failed")


def check_jobs():
    alerted = set(state["alerted_jobs"])
    seen_uids = set()
    cron_lines = []
    for ns in K8S_NAMESPACES:
        cron_jobs = {}  # cronjob name -> owned jobs
        for job in k8s_get(f"/apis/batch/v1/namespaces/{ns}/jobs").get("items", []):
            name = job["metadata"]["name"]
            uid = job["metadata"]["uid"]
            seen_uids.add(uid)
            owner = next(
                (o["name"] for o in job["metadata"].get("ownerReferences", []) or []
                 if o.get("kind") == "CronJob"), None)
            if owner:
                # A failing CronJob spawns a new failed Job every period, so
                # per-job one-time events would email every run. Handled below
                # as a keyed issue (alert once, re-alert per REALERT_HOURS,
                # RECOVERED when a run succeeds again).
                cron_jobs.setdefault(owner, []).append(job)
                continue
            if job_condition(job, "Failed") and uid not in alerted:
                events.append(f"Job {ns}/{name} FAILED ({job_failure_reason(job)})")
                alerted.add(uid)

        for cj_name, jobs in cron_jobs.items():
            terminal = [
                j for j in jobs
                if job_condition(j, "Failed") or job_condition(j, "Complete")]
            if not terminal:
                continue
            latest = max(
                terminal,
                key=lambda j: j.get("status", {}).get("startTime")
                or j["metadata"]["creationTimestamp"])
            if job_condition(latest, "Failed"):
                add_issue(
                    f"cronjob-failing:{ns}/{cj_name}",
                    f"CronJob {ns}/{cj_name}: latest run "
                    f"{latest['metadata']['name']} FAILED "
                    f"({job_failure_reason(latest)})")

        for cj in k8s_get(f"/apis/batch/v1/namespaces/{ns}/cronjobs").get("items", []):
            name = cj["metadata"]["name"]
            if cj.get("spec", {}).get("suspend"):
                continue
            period = cron_period_minutes(cj["spec"].get("schedule"))
            threshold = timedelta(minutes=period * 1.5 + 30)
            last_ok = parse_k8s_time(cj.get("status", {}).get("lastSuccessfulTime"))
            baseline = last_ok or parse_k8s_time(cj["metadata"]["creationTimestamp"])
            cron_lines.append(
                f"{ns}/{name}: schedule '{cj['spec'].get('schedule')}', "
                f"last success {last_ok.astimezone(ZoneInfo(TZ_NAME)).strftime('%Y-%m-%d %H:%M') if last_ok else 'never'}")
            if baseline and NOW - baseline > threshold:
                add_issue(f"cronjob-stale:{ns}/{name}",
                          f"CronJob {ns}/{name} has no successful run in {NOW - baseline} "
                          f"(schedule '{cj['spec'].get('schedule')}', expected within {threshold})")
    state["alerted_jobs"] = sorted(alerted & seen_uids)
    digest.append(("CronJobs (last success)", "\n".join(cron_lines)))


def check_xnat_web():
    try:
        status, _ = http_get(f"{XNAT_INTERNAL_URL}/", timeout=30)
        if status >= 400:
            add_issue("xnat-web", f"XNAT internal URL returned HTTP {status}")
    except Exception as exc:
        add_issue("xnat-web", f"XNAT unreachable at {XNAT_INTERNAL_URL}: {exc}")

    try:
        status, _ = http_get(f"{XNAT_PUBLIC_URL}/", timeout=30)
        if status >= 400:
            add_issue("xnat-public", f"XNAT public URL returned HTTP {status}")
    except Exception as exc:
        add_issue("xnat-public", f"XNAT public URL unreachable ({XNAT_PUBLIC_URL}): {exc}")


def check_tls_cert():
    host = urllib.parse.urlparse(XNAT_PUBLIC_URL).hostname
    ctx = ssl.create_default_context()
    with socket.create_connection((host, 443), timeout=30) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as tls:
            cert = tls.getpeercert()
    not_after = datetime.strptime(cert["notAfter"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
    days_left = (not_after - NOW).days
    digest.append(("TLS certificate", f"{host} expires {not_after:%Y-%m-%d} ({days_left} days)"))
    if days_left < CERT_WARN_DAYS:
        add_issue("tls-cert", f"TLS certificate for {host} expires in {days_left} days ({not_after:%Y-%m-%d})")


def xnat_login():
    # Use one JSESSION and log out: Basic auth mints a new server-side session
    # per request, and with the 8-hour sessionTimeout leaked sessions pile up
    # toward concurrentMaxSessions (1000) and 401-lock the account.
    req = urllib.request.Request(
        f"{XNAT_INTERNAL_URL}/data/JSESSION", method="POST",
        headers=xnat_auth_header())
    with urllib.request.urlopen(req, timeout=30) as resp:
        return {"Cookie": f"JSESSIONID={resp.read().decode().strip()}"}


def xnat_logout(cookie):
    try:
        urllib.request.urlopen(urllib.request.Request(
            f"{XNAT_INTERNAL_URL}/data/JSESSION", method="DELETE",
            headers=cookie), timeout=30)
    except Exception:
        pass


def check_container_service(cookie):
    status, body = http_get(f"{XNAT_INTERNAL_URL}/xapi/docker/server",
                            headers=cookie, timeout=30)
    info = json.loads(body)
    if info.get("ping") is not True:
        add_issue("container-service",
                  f"Container Service Docker ping failed: {json.dumps(info)[:300]}")


def check_xnat_sessions(cookie):
    # Early warning for server-side session pileup (a REST script that leaks
    # sessions via per-request Basic auth). At concurrentMaxSessions (default
    # 1000) XNAT 401-locks the account even with correct credentials; alert
    # well before that. Recovery on this deployment is an xnat-web restart,
    # because there is no second site administrator available to invalidate
    # the locked admin user's sessions through the API.
    counts = []
    for user in XNAT_SESSION_USERS:
        try:
            status, body = http_get(
                f"{XNAT_INTERNAL_URL}/xapi/users/active/{user}",
                headers=cookie, timeout=30)
            try:
                n = len(json.loads(body))
            except ValueError:
                n = 0
        except urllib.error.HTTPError as exc:
            # XNAT answers 304 (not an empty list) when the user has no
            # active sessions.
            if exc.code != 304:
                raise
            n = 0
        counts.append(f"{user}={n}")
        if n > XNAT_SESSION_WARN:
            add_issue(
                f"xnat-sessions:{user}",
                f"XNAT user '{user}' has {n} active server-side sessions "
                f"(warn >{XNAT_SESSION_WARN}; XNAT rejects logins at "
                f"concurrentMaxSessions) — a REST script is likely "
                f"leaking sessions via per-request Basic auth. Fix the client, "
                f"then restart statefulset/xnat-web to clear Tomcat's sessions.")
    digest.append(("XNAT active sessions", ", ".join(counts)))


def xnat_preference(cookie, name):
    _, body = http_get(
        f"{XNAT_INTERNAL_URL}/xapi/jupyterhub/preferences/{name}",
        headers=cookie, timeout=30)
    value = json.loads(body)
    if isinstance(value, dict):
        return value.get(name)
    return value


def check_jupyterhub(cookie):
    # Exercise the same service token and API URL used by the XNAT plugin.
    # A plain unauthenticated Hub health check would miss token drift or a
    # disabled/missing service identity.
    api_url = str(xnat_preference(cookie, "jupyterHubApiUrl") or "").rstrip("/")
    api_token = str(xnat_preference(cookie, "jupyterHubToken") or "")
    all_users = xnat_preference(cookie, "allUsersCanStartJupyter")
    max_named = int(xnat_preference(cookie, "maxNamedServers") or 0)

    if not api_url or not api_token:
        add_issue(
            "jupyterhub-config",
            "XNAT JupyterHub API URL or service token is not configured.")
        return
    if all_users is not True:
        add_issue(
            "jupyterhub-all-users",
            "XNAT JupyterHub preference allUsersCanStartJupyter is not true; "
            "ordinary users cannot launch notebooks.")

    headers = {"Authorization": f"token {api_token}"}
    status, _ = http_get(f"{api_url}/info", headers=headers, timeout=30)
    if status != 200:
        add_issue(
            "jupyterhub-service-auth",
            f"XNAT JupyterHub service credential returned HTTP {status} from {api_url}/info.")
        return

    _, body = http_get(
        f"{api_url}/users?include_stopped_servers=1",
        headers=headers, timeout=30)
    users = json.loads(body)
    stale_cutoff = NOW - timedelta(minutes=JUPYTER_STALE_MINUTES)
    stale = []
    at_limit = []
    for user in users:
        # The named-server limit only counts named servers. JupyterHub omits
        # stopped servers unless include_stopped_servers is requested, even
        # though those hidden records still count against the limit.
        servers = {
            name: server
            for name, server in (user.get("servers", {}) or {}).items()
            if name
        }
        blocked = []
        for server_name, server in servers.items():
            last_activity = parse_iso_time(server.get("last_activity"))
            is_old = last_activity is None or last_activity < stale_cutoff
            is_stopped = server.get("stopped") is True or (
                not server.get("ready") and not server.get("pending"))
            is_stalled_spawn = server.get("pending") == "spawn" and is_old
            if (is_stopped and is_old) or is_stalled_spawn:
                blocked.append(server_name)
                stale.append(f"{user['name']}/{server_name}")
        if max_named and len(servers) >= max_named and blocked:
            at_limit.append(user["name"])

    if stale:
        listing = ", ".join(stale[:20])
        more = f" (+{len(stale) - 20} more)" if len(stale) > 20 else ""
        add_issue(
            "jupyterhub-stale-servers",
            f"JupyterHub has {len(stale)} stopped or stalled named server(s) older than "
            f"{JUPYTER_STALE_MINUTES} minutes: {listing}{more}. "
            "These records can consume the per-user named-server limit; remove them "
            "with the JupyterHub API using DELETE and JSON body {\"remove\": true}.")
    if at_limit:
        add_issue(
            "jupyterhub-users-blocked",
            "JupyterHub users at the named-server limit because stale servers remain: "
            + ", ".join(at_limit[:20]))

    digest.append((
        "JupyterHub",
        f"service API HTTP {status}; allUsersCanStartJupyter={all_users}; "
        f"users={len(users)}; stale named servers={len(stale)}"))


def check_xnat_authenticated_services():
    """Use one XNAT JSESSION for every authenticated monitor check."""
    try:
        cookie = xnat_login()
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            add_issue(
                "xnat-auth",
                "XNAT rejected the monitor admin login with HTTP 401. If the "
                "credentials have not changed and failed_login_attempts is zero, "
                "the account has probably reached XNAT's 1,000 concurrent-session "
                "ceiling. Find and fix the REST client leaking HTTP-Basic sessions, "
                "then restart statefulset/xnat-web to clear Tomcat's session cache."
            )
            return
        raise

    try:
        run_check("container-service", lambda: check_container_service(cookie))
        run_check("xnat-sessions", lambda: check_xnat_sessions(cookie))
        run_check("jupyterhub", lambda: check_jupyterhub(cookie))
    finally:
        xnat_logout(cookie)


def check_jupyter_volumes():
    volumes = k8s_get(
        "/apis/longhorn.io/v1beta2/namespaces/longhorn-system/volumes").get("items", [])
    replicas = k8s_get(
        "/apis/longhorn.io/v1beta2/namespaces/longhorn-system/replicas").get("items", [])
    replicas_by_volume = {}
    for replica in replicas:
        metadata = replica.get("metadata", {})
        spec = replica.get("spec", {})
        volume_name = (
            spec.get("volumeName")
            or metadata.get("labels", {}).get("longhornvolume"))
        if volume_name:
            replicas_by_volume.setdefault(volume_name, []).append(replica)
    bad = []
    total = 0
    cutoff = NOW - timedelta(minutes=JUPYTER_STALE_MINUTES)
    for volume in volumes:
        metadata = volume.get("metadata", {})
        status = volume.get("status", {})
        k8s = status.get("kubernetesStatus", {}) or {}
        pvc = k8s.get("pvcName", "")
        if k8s.get("namespace") != "jupyter" or not pvc.startswith("jupyter-"):
            continue
        total += 1
        created = parse_k8s_time(metadata.get("creationTimestamp"))
        if created and created >= cutoff:
            continue
        robustness = (status.get("robustness") or "unknown").lower()
        scheduled = next((
            condition.get("status")
            for condition in status.get("conditions", []) or []
            if condition.get("type") == "Scheduled"), None)
        # Longhorn reports robustness=unknown whenever a healthy volume is
        # detached. That is normal after JupyterHub culls an idle notebook.
        # A never-usable home volume is distinguishable because none of its
        # replicas ever acquired healthyAt (cassidyl's failed first PVC), or
        # its replicas have failedAt set.
        volume_replicas = replicas_by_volume.get(metadata.get("name"), [])
        has_healthy_replica = any(
            replica.get("spec", {}).get("healthyAt")
            and not replica.get("spec", {}).get("failedAt")
            for replica in volume_replicas)
        unhealthy = (
            robustness in {"faulted", "degraded"}
            or scheduled == "False"
            or (robustness == "unknown" and not has_healthy_replica)
        )
        if unhealthy:
            bad.append(
                f"{pvc} (volume {metadata.get('name')}, state={status.get('state')}, "
                f"robustness={robustness}, scheduled={scheduled}, "
                f"healthyReplica={has_healthy_replica})")

    if bad:
        add_issue(
            "jupyterhub-home-volumes",
            "Unhealthy JupyterHub home volume(s) will prevent notebook pods from starting:\n"
            + "\n".join(bad[:20]))
    digest.append((
        "Jupyter home volumes",
        f"{total} Longhorn volume(s), {len(bad)} unhealthy"))


def check_database():
    conn = pg8000.native.Connection(
        PGUSER, host=PGHOST, port=PGPORT, database=PGDATABASE, password=PGPASSWORD, timeout=30)
    try:
        # New failed workflows (one-time events, deduplicated by workflow id).
        # launch_time is naive local wall-clock in the XNAT application
        # timezone, so compare against now() shifted into that timezone.
        rows = conn.run(
            """
            select wrk_workflowdata_id, pipeline_name, id, externalid, status,
                   to_char(launch_time, 'YYYY-MM-DD HH24:MI') as launched
            from wrk_workflowdata
            where status ilike 'Failed%'
              and status not ilike '%dismissed%'
              and launch_time > (now() at time zone :tz) - make_interval(days => :days)
            order by wrk_workflowdata_id
            """,
            days=WORKFLOW_LOOKBACK_DAYS, tz=TZ_NAME)
        alerted = set(state["alerted_workflows"])
        current_ids = {row[0] for row in rows}
        fresh = [row for row in rows if row[0] not in alerted]
        for wf_id, pipeline, data_id, project, status_, launched in fresh[:20]:
            events.append(
                f"Workflow FAILED: {pipeline} on {data_id} (project {project}), "
                f"status '{status_}', launched {launched} (workflow id {wf_id})")
        if len(fresh) > 20:
            events.append(f"...and {len(fresh) - 20} more failed workflows (see XNAT admin UI)")
        state["alerted_workflows"] = sorted((alerted & current_ids) | {r[0] for r in fresh})

        # Pending user-initiated project access requests (persistent
        # conditions: re-alert daily until approved/denied, recovery notice
        # when handled). XNAT 1.9.3's Access tab filters these rows out because
        # they have user_id set and email NULL, so include the legacy approval
        # form URL that XNAT normally sends to project owners by email.
        pars = conn.run(
            """
            select p.par_id, p.proj_id, p.user_id, p.level,
                   to_char(p.create_date, 'YYYY-MM-DD') as requested,
                   coalesce(u.login, '?'), coalesce(u.email, '?'),
                   coalesce(u.firstname || ' ' || u.lastname, '?')
            from xs_par_table p
            left join xdat_user u on u.xdat_user_id = p.user_id
            where p.approved is null and p.user_id is not null
            order by p.par_id
            """)
        par_lines = []
        for par_id, proj, user_id, level, requested, login, email_, fullname in pars:
            approval_url = project_access_request_url(proj, user_id, level)
            detail = (f"User '{login}' ({fullname}, {email_}) requested '{level}' access "
                      f"to project '{proj}' on {requested}.\n"
                      f"Approve or deny (sign in to XNAT first):\n{approval_url}\n"
                      f"XNAT 1.9.3 does not show user-initiated requests in the "
                      f"project Access tab.")
            add_issue(f"access-request:{par_id}", detail)
            par_lines.append(f"#{par_id} {login} -> {proj} ({level}) since {requested}")
        digest.append(("Pending access requests",
                       "\n".join(par_lines) if par_lines else "none"))

        # Digest: workflow activity in the last 24 hours.
        stats = conn.run(
            """
            select status, count(*) from wrk_workflowdata
            where launch_time > (now() at time zone :tz) - interval '24 hours'
            group by status order by count(*) desc
            """, tz=TZ_NAME)
        digest.append(("Workflows (last 24h)",
                       "\n".join(f"{s}: {c}" for s, c in stats) if stats else "none"))
    finally:
        conn.close()


def filer_ls(path):
    url = f"{FILER_URL}{urllib.parse.quote(path)}?limit=1000"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp).get("Entries") or []


def filer_read(path):
    url = f"{FILER_URL}{urllib.parse.quote(path)}"
    with urllib.request.urlopen(url, timeout=60) as resp:
        return resp.read()


def filer_is_dir(entry):
    return bool(entry.get("Mode", 0) & 0x80000000)


def filer_subtree_has_files(path, depth=0):
    if depth > 6:
        return True
    for entry in filer_ls(path):
        if not filer_is_dir(entry):
            return True
        if filer_subtree_has_files(entry["FullPath"], depth + 1):
            return True
    return False


def check_ingest_backlog():
    cutoff = NOW - timedelta(hours=STAGED_MAX_AGE_HOURS)
    stuck = []
    counts = {}
    for prefix in ("staged", "incoming"):
        entries = filer_ls(f"{INGEST_BUCKET}/{prefix}/")
        candidates = []
        for entry in entries:
            # Edge uploads are published as incoming/<edge>/<session>. Age
            # the session, not the long-lived edge directory: otherwise any
            # new upload beneath an old edge prefix is reported as >24h old.
            if prefix == "incoming" and filer_is_dir(entry):
                children = filer_ls(entry["FullPath"].rstrip("/") + "/")
                candidates.extend(children)
            else:
                candidates.append(entry)
        counts[prefix] = len(candidates)
        for entry in candidates:
            name = entry["FullPath"].rsplit("/", 1)[-1]
            if name.startswith("."):
                continue
            mtime = entry.get("Mtime")
            try:
                modified = datetime.fromisoformat(mtime).astimezone(timezone.utc)
            except (TypeError, ValueError):
                continue
            if modified < cutoff and filer_is_dir(entry) and filer_subtree_has_files(entry["FullPath"]):
                display_path = entry["FullPath"].removeprefix(INGEST_BUCKET + "/")
                stuck.append(f"{display_path} (untouched since {modified:%Y-%m-%d %H:%M}Z)")
    try:
        counts["uploaded"] = len(filer_ls(f"{INGEST_BUCKET}/uploaded/"))
    except Exception:
        counts["uploaded"] = "?"
    digest.append(("Ingest bucket", ", ".join(f"{k}: {v} entries" for k, v in counts.items())))
    if stuck:
        listing = "\n".join(stuck[:10])
        more = f"\n...and {len(stuck) - 10} more" if len(stuck) > 10 else ""
        add_issue("ingest-backlog",
                  f"{len(stuck)} ingest prefix(es) with files older than "
                  f"{STAGED_MAX_AGE_HOURS}h not uploaded to XNAT:\n{listing}{more}\n"
                  f"Check the xnat-upload/xnat-ingest-upload pod logs.")


def check_edge_ingest_health():
    max_age = timedelta(minutes=EDGE_HEALTH_MAX_AGE_MINUTES)
    summary = []
    object_names = (
        "edge-ingest-auto-label-health.json",
        "edge-ingest-samba-health.json",
    )

    for edge in EXPECTED_EDGES:
        edge_rows = []
        for object_name in object_names:
            component = object_name.removeprefix("edge-ingest-").removesuffix("-health.json")
            path = f"{INGEST_BUCKET}/health/{edge}/{object_name}"
            try:
                payload = json.loads(filer_read(path))
            except urllib.error.HTTPError as exc:
                if exc.code == 404:
                    add_issue(
                        f"edge-health-missing:{edge}:{component}",
                        f"Edge {edge} has not published its {component} ingest heartbeat. "
                        "Blocked or misrouted data can be silent while this heartbeat is missing."
                    )
                    edge_rows.append(f"{component}: missing")
                    continue
                raise

            updated = parse_iso_time(payload.get("updated"))
            if updated is None:
                add_issue(
                    f"edge-health-invalid:{edge}:{component}",
                    f"Edge {edge} published an invalid {component} ingest heartbeat "
                    f"without a parseable updated timestamp."
                )
                edge_rows.append(f"{component}: invalid")
                continue
            updated = updated.astimezone(timezone.utc)
            age = NOW - updated
            if age > max_age:
                add_issue(
                    f"edge-health-stale:{edge}:{component}",
                    f"Edge {edge} {component} ingest heartbeat is {age} old "
                    f"(maximum {EDGE_HEALTH_MAX_AGE_MINUTES} minutes). "
                    "The edge sorter or health publication path may be down."
                )

            blocked_uploads = payload.get("blocked_uploads") or []
            failed_uploads = payload.get("failed_uploads") or []
            fallback_studies = payload.get("fallback_studies") or []
            blocked_studies = payload.get("blocked_studies") or []
            edge_rows.append(
                f"{component}: age {int(max(age.total_seconds(), 0))}s, "
                f"{len(blocked_uploads)} blocked raw, {len(failed_uploads)} failed raw, "
                f"{len(fallback_studies)} fallback DICOM, {len(blocked_studies)} blocked DICOM"
            )

            for item in blocked_uploads:
                group = str(item.get("group", "?"))
                project = str(item.get("project", "?"))
                subject = str(item.get("subject", "?"))
                add_issue(
                    f"edge-raw-blocked:{edge}:{group}:{project}:{subject}",
                    f"Raw upload is blocked on {edge}: {group}/{project}/{subject} "
                    f"({item.get('files', '?')} files, "
                    f"{float(item.get('bytes', 0)) / 1e9:.2f} GB).\n"
                    f"Reason: {item.get('reason', 'project is not admitted')}.\n"
                    "Add the intended project to the edge allow-list or send a correctly "
                    "routed DICOM study for that project; the source data remains on the edge."
                )

            for item in failed_uploads:
                group = str(item.get("group", "?"))
                project = str(item.get("project", "?"))
                subject = str(item.get("subject", "?"))
                add_issue(
                    f"edge-raw-failed:{edge}:{group}:{project}:{subject}",
                    f"Raw upload staging failed on {edge}: {group}/{project}/{subject}.\n"
                    f"Error: {item.get('message', 'unknown error')}\n"
                    "The source data was preserved for retry."
                )

            for item in fallback_studies:
                study = str(item.get("study", "?"))
                value = str(item.get("value", "")) or "(empty)"
                target = str(item.get("target_project", "misc"))
                add_issue(
                    f"edge-dicom-fallback:{edge}:{study}",
                    f"DICOM study {study} on {edge} has unroutable "
                    f"{item.get('field', 'PatientID')} '{value}' and will be sent to "
                    f"fallback project '{target}'.\n"
                    "If the operator aborted a send, corrected the scanner ID, and resent, "
                    "check for reused SOP Instance UIDs: Orthanc may have retained the first "
                    "copy unless OverwriteInstances is enabled."
                )

            for item in blocked_studies:
                study = str(item.get("study", "?"))
                project = str(item.get("project", "?"))
                add_issue(
                    f"edge-dicom-blocked:{edge}:{study}",
                    f"DICOM study {study} on {edge} is blocked from ingestion "
                    f"(project '{project}').\nReason: {item.get('reason', 'routing rejected')}."
                )

        summary.append(f"{edge}: " + "; ".join(edge_rows))

    digest.append(("Edge ingest health", "\n".join(summary) if summary else "no edges configured"))


def check_db_backup():
    # Nightly pg_dump freshness, read through the dedicated object-store
    # FUSE hostPath mount (gs://<bucket>/db-backups/, written by the 2am
    # xnat-gcs-archiver). Alerts when the newest dump is stale, suspiciously
    # small, or the directory is unreadable (gcsfuse down).
    try:
        dumps = [e for e in os.scandir(DB_BACKUP_DIR)
                 if e.is_file() and e.name.endswith(".sql.gz")]
    except OSError as exc:
        add_issue("db-backup",
                  f"Cannot read DB backup dir {DB_BACKUP_DIR}: {exc} "
                  f"(object-store FUSE mount missing or xnat-gcs-fuse down?)")
        return
    if not dumps:
        add_issue("db-backup", f"No database dumps found in {DB_BACKUP_DIR}")
        return
    newest = max(dumps, key=lambda e: e.stat().st_mtime)
    size = newest.stat().st_size
    mtime = datetime.fromtimestamp(newest.stat().st_mtime, tz=timezone.utc)
    age_hours = (NOW - mtime).total_seconds() / 3600
    digest.append(("DB backup",
                   f"{newest.name}: {size / 1e6:.1f} MB, {age_hours:.1f}h old "
                   f"({len(dumps)} dumps retained)"))
    if age_hours > DB_BACKUP_MAX_AGE_HOURS:
        add_issue("db-backup",
                  f"Newest database dump {newest.name} is {age_hours:.0f}h old "
                  f"(threshold {DB_BACKUP_MAX_AGE_HOURS}h) — the nightly "
                  f"xnat-gcs-archiver pg_dump is not landing in GCS. Check the "
                  f"latest xnat-gcs-archiver job logs in ais-xnat.")
    elif size < 1_000_000:
        add_issue("db-backup",
                  f"Newest database dump {newest.name} is only {size} bytes — "
                  f"likely truncated or empty.")


# ── Alert/recovery/digest emails ─────────────────────────────────────

def send_email(subject, body):
    msg = EmailMessage()
    msg["From"] = SMTP_USER
    msg["To"] = ALERT_TO
    msg["Subject"] = f"{SUBJECT_PREFIX} {subject}"
    msg.set_content(body)
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30) as smtp:
        smtp.starttls()
        smtp.login(SMTP_USER, SMTP_PASS)
        smtp.send_message(msg)
    print(f"Sent email: {subject}")


def process_alerts():
    previous = state["alerts"]
    new_keys = sorted(k for k in issues if k not in previous)
    resolved = sorted(k for k in previous if k not in issues)
    realert_cutoff = NOW - timedelta(hours=REALERT_HOURS)
    ongoing = sorted(
        k for k in issues
        if k in previous
        and datetime.fromisoformat(previous[k]["last_alerted"]) < realert_cutoff)

    sections = []
    if new_keys:
        sections.append("NEW PROBLEMS\n============\n" + "\n\n".join(
            f"[{k}]\n{issues[k]}" for k in new_keys))
    if events:
        sections.append("EVENTS\n======\n" + "\n".join(f"- {e}" for e in events))
    if ongoing:
        sections.append(f"STILL FAILING (unresolved for >{REALERT_HOURS}h)\n"
                        "=============\n" + "\n\n".join(
                            f"[{k}] since {previous[k]['first']}\n{issues[k]}" for k in ongoing))
    if resolved:
        sections.append("RESOLVED\n========\n" + "\n".join(
            f"- [{k}] {previous[k].get('summary', '')}" for k in resolved))

    if sections:
        parts = []
        if new_keys:
            parts.append(f"{len(new_keys)} new")
        if events:
            parts.append(f"{len(events)} event(s)")
        if ongoing:
            parts.append(f"{len(ongoing)} ongoing")
        if resolved:
            parts.append(f"{len(resolved)} resolved")
        flavour = "RECOVERED" if resolved and not (new_keys or events or ongoing) else "ALERT"
        body = (f"Platform monitor run at {LOCAL_NOW:%Y-%m-%d %H:%M %Z}\n\n"
                + "\n\n".join(sections)
                + "\n\n--\nSent by platform-monitor CronJob (ais-xnat namespace).\n"
                  "Manifest: manifests/platform-monitor.yaml in ais-devstack.\n")
        send_email(f"{flavour}: {', '.join(parts)}", body)

    # Update alert state only after the email went out (or none was needed).
    updated = {}
    for key, detail in issues.items():
        entry = previous.get(key) or {"first": NOW.isoformat()}
        if key in new_keys or key in ongoing:
            entry["last_alerted"] = NOW.isoformat()
        entry.setdefault("last_alerted", NOW.isoformat())
        entry["summary"] = detail.splitlines()[0][:200]
        updated[key] = entry
    state["alerts"] = updated


def maybe_send_digest():
    today = LOCAL_NOW.strftime("%Y-%m-%d")
    if not FORCE_DIGEST:
        if LOCAL_NOW.hour != DIGEST_HOUR or state.get("last_digest_date") == today:
            return
    lines = [f"Daily platform digest for {today} ({LOCAL_NOW:%H:%M %Z})", ""]
    if issues:
        lines.append("ACTIVE PROBLEMS")
        lines.append("---------------")
        for key in sorted(issues):
            first = state["alerts"].get(key, {}).get("first", "")[:16]
            lines.append(f"[{key}] (since {first})")
            lines.append(issues[key])
            lines.append("")
    else:
        lines.append("No active problems.")
        lines.append("")
    for section, text in digest:
        lines.append(section)
        lines.append("-" * len(section))
        lines.append(text if text else "(no data)")
        lines.append("")
    lines.append("--")
    lines.append("If this digest stops arriving, the platform-monitor CronJob itself is broken:")
    lines.append("sudo kubectl -n ais-xnat get jobs | grep platform-monitor")
    send_email(f"Daily digest — {'PROBLEMS: ' + str(len(issues)) if issues else 'all OK'}",
               "\n".join(lines))
    state["last_digest_date"] = today


# ── Main ─────────────────────────────────────────────────────────────

def main():
    run_check("disk", check_disk)
    run_check("pods", check_pods)
    run_check("jobs", check_jobs)
    run_check("xnat-web", check_xnat_web)
    run_check("tls-cert", check_tls_cert)
    run_check("xnat-authenticated-services", check_xnat_authenticated_services)
    run_check("jupyter-volumes", check_jupyter_volumes)
    run_check("database", check_database)
    run_check("edge-ingest-health", check_edge_ingest_health)
    run_check("ingest-backlog", check_ingest_backlog)
    run_check("db-backup", check_db_backup)

    for key in sorted(issues):
        print(f"ISSUE [{key}] {issues[key].splitlines()[0]}")
    for event in events:
        print(f"EVENT {event}")

    process_alerts()
    maybe_send_digest()
    save_state(state)
    print(f"OK: {len(issues)} active issue(s), {len(events)} event(s)")


if __name__ == "__main__":
    main()
