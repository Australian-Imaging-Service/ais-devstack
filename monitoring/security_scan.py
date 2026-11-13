#!/usr/bin/env python3
"""Daily, read-only vulnerability inventory; no upgrades or email sending."""

import fcntl
import http.client
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import urllib.request
from datetime import datetime, timedelta, timezone


KEV_URL = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
REPORT_FILE = os.environ.get("SECURITY_REPORT_FILE", "/state/security-report.json")
CACHE_DIR = os.environ.get("TRIVY_CACHE_DIR", "/state/trivy-cache")
HOST = os.environ.get("HOST_ROOT", "/host").rstrip("/")
SERVICE_ACCOUNT = Path("/var/run/secrets/kubernetes.io/serviceaccount")


def utcnow():
    return datetime.now(timezone.utc)


def timestamp(value):
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("timestamp has no timezone")
    return result


def api_get(path):
    token = (SERVICE_ACCOUNT / "token").read_text().strip()
    request = urllib.request.Request("https://kubernetes.default.svc" + path,
                                     headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=30, context=ssl.create_default_context(
            cafile=str(SERVICE_ACCOUNT / "ca.crt"))) as response:
        return json.load(response)


class DockerConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(30)
        # /var/run is an absolute symlink to /run on the host. Resolve it
        # explicitly so the /host bind does not follow into the scanner pod.
        self.sock.connect(f"{HOST}/run/docker.sock")


def docker_containers():
    connection = DockerConnection("localhost")
    try:
        connection.request("GET", "/containers/json")
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError(f"Docker inventory returned HTTP {response.status}")
        return json.load(response)
    finally:
        connection.close()


def host_runtime_directory():
    current = Path(HOST + "/var/lib/rancher/k3s/data/current")
    if current.is_symlink():
        destination = os.readlink(current)
        # k3s uses an absolute host symlink; it must stay within /host.
        current = (Path(HOST + destination) if destination.startswith("/")
                   else current.parent / destination)
    return str(current / "bin")


def image_targets(pods, cronjobs, containers, node):
    """Use immutable running digests; keep inactive scheduled jobs in coverage."""
    targets = {}

    def add(runtime, ref, owner, expected_id=None):
        if runtime == "containerd" and "@" not in ref:
            # containerd stores canonical names; short names can pass metadata
            # lookup but fail when Trivy subsequently opens image layers.
            first = ref.split("/", 1)[0]
            if "/" not in ref:
                ref = "docker.io/library/" + ref
            elif "." not in first and ":" not in first and first != "localhost":
                ref = "docker.io/" + ref
        target = targets.setdefault((runtime, ref), {
            "kind": "image", "runtime": runtime, "ref": ref, "owners": []})
        target["owners"].append(owner)
        if expected_id:
            target["expected_id"] = expected_id

    for pod in pods:
        if pod.get("status", {}).get("phase") != "Running":
            continue
        if pod["spec"].get("nodeName") != node:
            raise ValueError(f"Pod on unscanned node: {pod['metadata']['name']}")
        statuses = {item["name"]: item for item in
                    pod["status"].get("containerStatuses", [])}
        for container in pod["spec"].get("containers", []):
            image_id = statuses.get(container["name"], {}).get("imageID", "")
            for prefix in ("docker-pullable://", "containerd://", "docker://"):
                image_id = image_id.removeprefix(prefix)
            ref = image_id if "@sha256:" in image_id else container["image"]
            owner = f"{pod['metadata']['namespace']}/{pod['metadata']['name']}/{container['name']}"
            add("containerd", ref, owner, image_id if image_id.startswith("sha256:") else None)
    for cronjob in cronjobs:
        if cronjob["spec"].get("suspend"):
            continue
        spec = cronjob["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        for container in spec.get("containers", []) + spec.get("initContainers", []):
            add("containerd", container["image"],
                f"CronJob {cronjob['metadata']['namespace']}/{cronjob['metadata']['name']}")
    for container in containers:
        add("docker", container["ImageID"],
            "Docker " + ",".join(container.get("Names", [])))
    return list(targets.values())


def result_rows(document):
    """Support both standalone image/rootfs and Kubernetes infrastructure reports."""
    for result in document.get("Results", []):
        yield result
    for resource in document.get("Resources", []):
        yield from resource.get("Results", [])


def collect_findings(document, target):
    findings = []
    for result in result_rows(document):
        for vulnerability in result.get("Vulnerabilities", []):
            if vulnerability.get("Status") == "not_affected":
                continue
            findings.append({
                "id": vulnerability["VulnerabilityID"],
                "package": vulnerability["PkgName"],
                "installed": vulnerability["InstalledVersion"],
                "fixed": vulnerability.get("FixedVersion", ""),
                "severity": vulnerability.get("Severity", "UNKNOWN"),
                "title": vulnerability.get("Title", ""),
                "url": vulnerability.get("PrimaryURL", ""),
                "target": target,
                "location": result.get("Target", ""),
            })
    return findings


def important_findings(findings, kev):
    """Deduplicate affected package versions across images without losing owners."""
    grouped = {}
    for item in findings:
        if item["id"] not in kev and not (
                item["severity"] in {"HIGH", "CRITICAL"} and item.get("fixed")):
            continue
        key = (item["id"], item["package"], item["installed"], item.get("fixed", ""))
        entry = grouped.setdefault(key, {**item, "targets": [], "kev": kev.get(item["id"])})
        if item["target"] not in entry["targets"]:
            entry["targets"].append(item["target"])
        if item["severity"] == "CRITICAL":
            entry["severity"] = "CRITICAL"
    return sorted(grouped.values(), key=lambda item: (
        not bool(item["kev"]), item["severity"] != "CRITICAL", item["id"], item["package"]))


def security_summary(report, now, max_age_hours=30, limit=20):
    if report.get("schema_version") != 1:
        raise ValueError("unsupported security report schema")
    completed = timestamp(report["completed_at"])
    if completed > now + timedelta(minutes=5):
        raise ValueError("security report timestamp is in the future")
    stale = now - timestamp(report["started_at"]) > timedelta(hours=max_age_hours)
    problems = list(report["errors"])
    if report["scanned_targets"] != report["total_targets"] or not report["total_targets"]:
        problems.append("Some inventory targets were not successfully scanned")
    if stale:
        problems.insert(0, f"STALE: scan is older than {max_age_hours} hours; run platform-security-scan")
    age = now - timestamp(report["database_updated_at"])
    if age > timedelta(hours=48):
        problems.append("Vulnerability database is older than 48 hours")
    by_cve = {}
    for item in report["important"]:
        by_cve.setdefault(item["id"], []).append(item)
    findings = list(by_cve.values())
    status = "INCOMPLETE — review coverage" if problems else (
        f"ACTION REQUIRED: {len(findings)} CVEs need exposure/remediation review" if findings
        else "No prioritized CVEs found in the scanned inventory")
    lines = [status, f"Scan completed: {completed:%Y-%m-%d %H:%M UTC}",
             f"Coverage: {report['scanned_targets']}/{report['total_targets']} targets scanned",
             f"Vulnerability DB: {report['database_updated_at']}",
             f"CISA KEV catalog: {report.get('kev_released_at') or 'UNKNOWN'}"]
    for problem in problems:
        lines.append(f"Coverage warning: {problem}")
    if problems:
        lines.append("Findings below are from available scan data; absence is not an all-clear.")
    for matches in findings[:limit]:
        item = matches[0]
        priority = "KNOWN EXPLOITED — prioritize urgently" if item["kev"] else item["severity"]
        targets = sorted({target for match in matches for target in match["targets"]})
        lines.extend(["", f"{item['id']} [{priority}] {item['title']}",
                      "Affected: " + "; ".join(targets[:6])])
        if len(targets) > 6:
            lines.append(f"Also affects {len(targets) - 6} other targets (see full report).")
        for match in matches[:3]:
            lines.append(f"Package: {match['package']} {match['installed']}; "
                         f"fixed version(s): {match['fixed'] or 'none published'}")
        if len(matches) > 3:
            lines.append(f"Also affects {len(matches) - 3} other package/version combinations (see full report).")
        if any(match.get("fixed") for match in matches):
            lines.append("Action: confirm exposure, then upgrade to a vendor-supported release fixing "
                         "these packages; rebuild/redeploy affected images, or patch host packages. "
                         "Use vendor mitigations where a matching fix is unavailable.")
        else:
            lines.append("Action: no published fix; apply vendor mitigations or restrict/disable the affected service.")
        if item["kev"]:
            lines.append("CISA action: " + item["kev"].get("requiredAction", "Follow vendor mitigations."))
        lines.append("Advisory: " + (item["url"] or f"https://www.cve.org/CVERecord?id={item['id']}"))
    if len(findings) > limit:
        lines.extend(["", f"{len(findings) - limit} additional prioritized CVEs in the full report."])
    lines.extend(["", f"Other findings without a published fix: {report['unfixed_high_critical']} High/Critical package occurrences (review vendor mitigations).",
                  "Full report on host: /srv/xnat-local-storage/monitoring/security-report.json",
                  "Coverage excludes remote edge hosts, stopped ad-hoc images, and unrecognized software. "
                  "Package matches require exposure review; the scanner does not prove exploitability."])
    return "\n".join(lines)


def run_trivy(arguments, output):
    command = ["trivy", *arguments, "--cache-dir", CACHE_DIR, "--quiet",
               "--skip-version-check", "--timeout", "8m", "--format", "json",
               "--list-all-pkgs=false", "--output", str(output)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=510)
    if result.returncode:
        raise RuntimeError(result.stderr.strip()[-1200:] or f"Trivy exit {result.returncode}")
    document = json.loads(output.read_text())
    if not list(result_rows(document)):
        raise ValueError("No supported packages/components detected")
    return document


def write_report(report):
    path = Path(REPORT_FILE)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(report, indent=2))
    temporary.replace(path)


def scan_target(target, output):
    args = target.get("args") or ["image", "--image-src", target["runtime"],
                                  "--scanners", "vuln", target["ref"]]
    try:
        document = run_trivy(args, output)
    except RuntimeError:
        # The runtime can have unpacked layers but lack blobs needed to export
        # an image. A registry fallback is safe only for an immutable digest.
        if target.get("runtime") != "containerd" or "@sha256:" not in target["ref"]:
            raise
        document = run_trivy(["image", "--image-src", "remote", "--scanners", "vuln",
                              target["ref"]], output)
        target["registry_fallback"] = True
    if target.get("expected_id") and document.get("Metadata", {}).get("ImageID") != target["expected_id"]:
        raise ValueError("Local image tag no longer matches the running container image ID")
    return document


def main():
    # CronJob concurrencyPolicy does not cover manually-created Jobs.
    lock_path = Path(REPORT_FILE).with_suffix(".lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("w") as scan_lock:
        try:
            fcntl.flock(scan_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another security scan is running; skipped without changing its report.")
            return 0
        return scan()


def scan():
    report = {"schema_version": 1, "started_at": utcnow().isoformat(), "errors": [],
              "findings": [], "targets": [], "scanned_targets": 0, "total_targets": 0}
    kev = {}
    try:
        request = urllib.request.Request(KEV_URL, headers={"User-Agent": "xnat-platform-monitor"})
        with urllib.request.urlopen(request, timeout=30) as response:
            catalog = json.load(response)
        if not catalog["vulnerabilities"] or len(catalog["vulnerabilities"]) != catalog["count"]:
            raise ValueError("Empty or incomplete KEV feed")
        report["kev_released_at"] = catalog["dateReleased"]
        if utcnow() - timestamp(catalog["dateReleased"]) > timedelta(days=14):
            raise ValueError("KEV feed is older than 14 days")
        kev = {entry["cveID"]: entry for entry in catalog["vulnerabilities"]}
    except Exception as exc:
        report["errors"].append(f"CISA known-exploited feed unavailable: {exc}")

    try:
        nodes = api_get("/api/v1/nodes")["items"]
        node = os.environ["NODE_NAME"]
        if len(nodes) != 1 or nodes[0]["metadata"]["name"] != node:
            report["errors"].append("Host/package coverage is limited to scanner node " + node)
        pods = api_get("/api/v1/pods")["items"]
        cronjobs = api_get("/apis/batch/v1/cronjobs")["items"]
        try:
            containers = docker_containers()
        except Exception as exc:
            report["errors"].append(f"Running Docker workload inventory unavailable: {exc}")
            containers = []
        targets = image_targets(pods, cronjobs, containers, node)
    except Exception as exc:
        report["errors"].append(f"Workload inventory unavailable: {exc}")
        targets = []

    with tempfile.TemporaryDirectory(prefix="security-scan-") as work:
        work = Path(work)
        kubeconfig = work / "kubeconfig.json"
        kubeconfig.write_text(json.dumps({"apiVersion": "v1", "kind": "Config",
            "clusters": [{"name": "local", "cluster": {"server": "https://kubernetes.default.svc",
                "certificate-authority": str(SERVICE_ACCOUNT / "ca.crt")}}],
            "users": [{"name": "scanner", "user": {"tokenFile": str(SERVICE_ACCOUNT / "token")}}],
            "contexts": [{"name": "local", "context": {"cluster": "local", "user": "scanner"}}],
            "current-context": "local"}))
        targets += [
            {"kind": "host", "ref": HOST, "owners": ["Host OS packages"],
             "args": ["rootfs", "--pkg-types", "os", "--scanners", "vuln", HOST]},
            {"kind": "plugins", "ref": f"{HOST}/srv/xnat-local-storage/xnat/plugins",
             "owners": ["XNAT mounted plugins"],
             "args": ["rootfs", "--pkg-types", "library", "--scanners", "vuln", f"{HOST}/srv/xnat-local-storage/xnat/plugins"]},
            {"kind": "runtime", "ref": f"{HOST}/usr/local/bin", "owners": ["Host k3s binaries"],
             "args": ["rootfs", "--pkg-types", "library", "--scanners", "vuln", f"{HOST}/usr/local/bin"]},
            {"kind": "runtime", "ref": host_runtime_directory(),
             "owners": ["Host containerd/runtime binaries"],
             "args": ["rootfs", "--pkg-types", "library", "--scanners", "vuln", host_runtime_directory()]},
            {"kind": "runtime", "ref": f"{HOST}/usr/bin/dockerd", "owners": ["Host Docker daemon"],
             "args": ["rootfs", "--pkg-types", "library", "--scanners", "vuln", f"{HOST}/usr/bin/dockerd"]},
            {"kind": "kubernetes", "ref": "control-plane", "owners": ["Kubernetes components"],
             "args": ["k8s", "--kubeconfig", str(kubeconfig), "--include-kinds", "node",
                      "--skip-images", "--disable-node-collector", "--scanners", "vuln", "--report", "all"]},
        ]
        report["total_targets"] = len(targets)
        os.environ["CONTAINERD_ADDRESS"] = f"{HOST}/run/k3s/containerd/containerd.sock"
        os.environ["CONTAINERD_NAMESPACE"] = "k8s.io"
        os.environ["DOCKER_HOST"] = f"unix://{HOST}/run/docker.sock"
        for target in targets:
            owners = sorted(set(target["owners"]))
            label = target["ref"] + " (" + "; ".join(owners[:2])
            label += (f"; +{len(owners) - 2} workloads" if len(owners) > 2 else "") + ")"
            print(f"Scanning {target['kind']}: {target['ref']}", flush=True)
            try:
                document = scan_target(target, work / "result.json")
                report["findings"].extend(collect_findings(document, label))
                report["scanned_targets"] += 1
                target["scanned"] = True
            except Exception as exc:
                target["error"] = str(exc)
                report["errors"].append(f"{label}: {exc}")
                print(f"INCOMPLETE: {label}: {exc}", flush=True)
            report["targets"].append({k: v for k, v in target.items() if k != "args"})

    try:
        metadata = json.loads((Path(CACHE_DIR) / "db/metadata.json").read_text())
        report["database_updated_at"] = metadata["UpdatedAt"]
    except Exception as exc:
        report["database_updated_at"] = "1970-01-01T00:00:00+00:00"
        report["errors"].append(f"Cannot verify vulnerability database freshness: {exc}")
    report["important"] = important_findings(report["findings"], kev)
    report["unfixed_high_critical"] = sum(
        item["severity"] in {"HIGH", "CRITICAL"} and not item["fixed"]
        for item in report["findings"])
    report["completed_at"] = utcnow().isoformat()
    write_report(report)
    print(security_summary(report, utcnow()), flush=True)
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
