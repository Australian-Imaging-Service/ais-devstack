import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
from datetime import datetime, timedelta, timezone
from pathlib import Path


def load_monitor():
    pg8000 = types.ModuleType("pg8000")
    pg8000_native = types.ModuleType("pg8000.native")
    pg8000.native = pg8000_native
    sys.modules.setdefault("pg8000", pg8000)
    sys.modules.setdefault("pg8000.native", pg8000_native)

    os.environ.setdefault("SMTP_USER", "test@example.invalid")
    os.environ.setdefault("SMTP_PASS", "test")
    os.environ.setdefault("XNAT_USER", "test")
    os.environ.setdefault("XNAT_PASS", "test")
    os.environ.setdefault("PGPASSWORD", "test")
    with tempfile.TemporaryDirectory() as state_dir:
        os.environ["STATE_FILE"] = str(Path(state_dir) / "state.json")
        path = Path(__file__).with_name("platform-monitor.py")
        spec = importlib.util.spec_from_file_location("platform_monitor", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module


MONITOR = load_monitor()


def pod(name, phase, owner_kind=None):
    metadata = {
        "name": name,
        "uid": f"uid-{name}",
        "creationTimestamp": "2020-01-01T00:00:00Z",
    }
    if owner_kind:
        metadata["ownerReferences"] = [{"kind": owner_kind, "name": "owner"}]
    return {"metadata": metadata, "status": {"phase": phase}}


class PodChecksTest(unittest.TestCase):
    def setUp(self):
        MONITOR.K8S_NAMESPACES = ["test"]
        MONITOR.issues = {}
        MONITOR.events = []
        MONITOR.digest = []
        MONITOR.state = {
            "alerts": {},
            "restart_counts": {},
            "alerted_jobs": [],
            "alerted_workflows": [],
        }

    def run_pod_check(self, pods):
        MONITOR.k8s_get = lambda _path: {"items": pods}
        MONITOR.check_pods()

    def test_terminal_job_pod_is_ignored(self):
        self.run_pod_check([pod("retained-failure", "Failed", "Job")])
        self.assertEqual({}, MONITOR.issues)

    def test_failed_non_job_pod_is_still_reported(self):
        self.run_pod_check([pod("failed-service", "Failed", "ReplicaSet")])
        self.assertIn("pod:test/failed-service", MONITOR.issues)

    def test_active_job_pod_is_still_checked(self):
        self.run_pod_check([pod("pending-job", "Pending", "Job")])
        self.assertIn("pod:test/pending-job", MONITOR.issues)


class JobChecksTest(unittest.TestCase):
    def setUp(self):
        MONITOR.K8S_NAMESPACES = ["test"]
        MONITOR.issues = {}
        MONITOR.events = []
        MONITOR.digest = []
        MONITOR.state = {
            "alerts": {},
            "restart_counts": {},
            "alerted_jobs": [],
            "alerted_workflows": [],
        }

    def test_failed_cronjob_remains_authoritative(self):
        started = (datetime.now(timezone.utc) - timedelta(minutes=1)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        failed_job = {
            "metadata": {
                "name": "worker-123",
                "uid": "job-uid",
                "creationTimestamp": started,
                "ownerReferences": [{"kind": "CronJob", "name": "worker"}],
            },
            "status": {
                "startTime": started,
                "conditions": [{
                    "type": "Failed",
                    "status": "True",
                    "reason": "BackoffLimitExceeded",
                    "message": "test failure",
                }],
            },
        }
        cronjob = {
            "metadata": {"name": "worker", "creationTimestamp": started},
            "spec": {"schedule": "*/15 * * * *"},
            "status": {"lastSuccessfulTime": started},
        }

        def k8s_get(path):
            return {"items": [failed_job] if path.endswith("/jobs") else [cronjob]}

        MONITOR.k8s_get = k8s_get
        MONITOR.check_jobs()
        self.assertIn("cronjob-failing:test/worker", MONITOR.issues)

    @staticmethod
    def _stamp(dt):
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")

    def _run(self, failed_at, last_successful_at):
        failed_job = {
            "metadata": {
                "name": "worker-123",
                "uid": "job-uid",
                "creationTimestamp": self._stamp(failed_at),
                "ownerReferences": [{"kind": "CronJob", "name": "worker"}],
            },
            "status": {
                "startTime": self._stamp(failed_at),
                "conditions": [{
                    "type": "Failed",
                    "status": "True",
                    "reason": "BackoffLimitExceeded",
                    "message": "test failure",
                }],
            },
        }
        cronjob = {
            "metadata": {
                "name": "worker",
                "creationTimestamp": self._stamp(failed_at),
            },
            "spec": {"schedule": "*/15 * * * *"},
            "status": {},
        }
        if last_successful_at is not None:
            cronjob["status"]["lastSuccessfulTime"] = self._stamp(
                last_successful_at)

        MONITOR.k8s_get = lambda path: {
            "items": [failed_job] if path.endswith("/jobs") else [cronjob]}
        MONITOR.check_jobs()

    def test_stale_failed_job_does_not_alert_after_recovery(self):
        """A retained failure from weeks ago must not alert once the CronJob
        has succeeded since -- Kubernetes keeps failed Jobs around, so the
        newest *terminal* Job can long outlive the outage that produced it."""
        now = datetime.now(timezone.utc)
        self._run(failed_at=now - timedelta(days=41),
                  last_successful_at=now - timedelta(minutes=1))
        self.assertNotIn("cronjob-failing:test/worker", MONITOR.issues)

    def test_failure_after_last_success_still_alerts(self):
        now = datetime.now(timezone.utc)
        self._run(failed_at=now - timedelta(minutes=1),
                  last_successful_at=now - timedelta(hours=2))
        self.assertIn("cronjob-failing:test/worker", MONITOR.issues)

    def test_failure_with_no_recorded_success_still_alerts(self):
        now = datetime.now(timezone.utc)
        self._run(failed_at=now - timedelta(minutes=1), last_successful_at=None)
        self.assertIn("cronjob-failing:test/worker", MONITOR.issues)


class EdgeBlockedChecksTest(unittest.TestCase):
    def setUp(self):
        MONITOR.EXPECTED_EDGES = ["edge-test"]
        MONITOR.EDGE_BLOCKED_GRACE_MINUTES = 30
        MONITOR.NOW = datetime.now(timezone.utc)
        MONITOR.issues = {}
        MONITOR.events = []
        MONITOR.digest = []
        MONITOR.state = {
            "alerts": {},
            "edge_blocked_seen": {},
        }

    @staticmethod
    def payload(blocked=None):
        return {
            "updated": MONITOR.NOW.isoformat(),
            "blocked_studies": blocked or [],
        }

    def run_edge_check(self, blocked=None):
        auto_label = self.payload(blocked)
        samba = self.payload()
        MONITOR.filer_read = lambda path: __import__("json").dumps(
            auto_label if "auto-label" in path else samba
        ).encode()
        MONITOR.check_edge_ingest_health()

    def test_new_project_block_is_suppressed_during_grace(self):
        self.run_edge_check([{
            "study": "study-1",
            "project": "new-project",
            "reason": "project is not in AIS_EDGE_AUTO_IMPORT_ALLOWED_PROJECTS",
        }])
        self.assertNotIn("edge-dicom-blocked:edge-test:study-1", MONITOR.issues)
        self.assertIn(
            "edge-dicom-blocked:edge-test:study-1",
            MONITOR.state["edge_blocked_seen"],
        )

    def test_persistent_project_block_alerts_after_grace(self):
        key = "edge-dicom-blocked:edge-test:study-1"
        MONITOR.state["edge_blocked_seen"][key] = (
            MONITOR.NOW - timedelta(minutes=31)
        ).isoformat()
        self.run_edge_check([{
            "study": "study-1",
            "project": "bad-project",
            "reason": "project is not in AIS_EDGE_AUTO_IMPORT_ALLOWED_PROJECTS",
        }])
        self.assertIn(key, MONITOR.issues)

    def test_transient_project_block_clears_without_alert(self):
        key = "edge-dicom-blocked:edge-test:study-1"
        MONITOR.state["edge_blocked_seen"][key] = MONITOR.NOW.isoformat()
        self.run_edge_check()
        self.assertNotIn(key, MONITOR.issues)
        self.assertNotIn(key, MONITOR.state["edge_blocked_seen"])

    def test_malformed_route_alerts_immediately(self):
        key = "edge-dicom-blocked:edge-test:study-1"
        self.run_edge_check([{
            "study": "study-1",
            "reason": "routing field does not match subject@group/project",
        }])
        self.assertIn(key, MONITOR.issues)


class JupyterHomeStorageTest(unittest.TestCase):
    def setUp(self):
        MONITOR.issues, MONITOR.digest = {}, []
        self.pod = {
            "metadata": {"uid": "pod-uid"}, "status": {"phase": "Running"},
            "spec": {"nodeName": "test-node", "volumes": [
                {"persistentVolumeClaim": {"claimName": "jupyter-test-home"}}]},
        }
        self.volume = {"metadata": {"name": "pvc-test"}, "status": {
            "kubernetesStatus": {"namespace": "jupyter", "pvcName": "jupyter-test-home"}}}

    def check(self, free, *, mounted=True, pods=None):
        pods = [self.pod] if pods is None else pods
        def get(path):
            return {"items": pods if path.endswith("/pods") else [self.volume]}
        with patch.dict(os.environ, {"NODE_NAME": "test-node"}), \
                patch.object(MONITOR, "k8s_get", side_effect=get), \
                patch.object(MONITOR.os.path, "ismount", return_value=mounted), \
                patch.object(MONITOR.os, "statvfs", return_value=types.SimpleNamespace(
                    f_blocks=100, f_frsize=2**30, f_bavail=free)) as stat:
            MONITOR.check_jupyter_home_storage()
        return stat

    def test_healthy_home(self):
        stat = self.check(60)
        self.assertEqual(MONITOR.issues, {})
        self.assertIn("pod-uid/volumes/kubernetes.io~csi/pvc-test/mount", stat.call_args.args[0])

    def test_full_home_alerts_even_if_longhorn_is_healthy(self):
        self.volume["status"]["robustness"] = "healthy"
        self.check(0)
        self.assertIn("CRITICAL", MONITOR.issues["jupyterhub-home-storage:jupyter-test-home"])

    def test_warning_before_home_is_full(self):
        self.check(15)
        self.assertIn("High", MONITOR.issues["jupyterhub-home-storage:jupyter-test-home"])

    def test_unmounted_path_never_reports_node_disk_capacity(self):
        stat = self.check(60, mounted=False)
        stat.assert_not_called()
        self.assertIn("jupyterhub-home-storage-unavailable", MONITOR.issues)

    def test_shared_home_checked_once_for_multiple_named_servers(self):
        stat = self.check(60, pods=[self.pod, self.pod])
        stat.assert_called_once()

    def test_detached_and_other_node_homes_are_skipped(self):
        self.pod["status"]["phase"] = "Succeeded"
        self.check(0).assert_not_called()
        self.pod["status"]["phase"] = "Running"
        self.pod["spec"]["nodeName"] = "another-node"
        self.check(0).assert_not_called()
        self.assertEqual(MONITOR.issues, {})


class XnatUpdatesTest(unittest.TestCase):
    def setUp(self):
        MONITOR.digest = []
        MONITOR.issues = {}
        MONITOR.state = {"alerts": {}}

    @staticmethod
    def release_page(*versions):
        return "".join(
            f'<a href="https://github.com/NrgXnat/{repo}/releases/download/'
            f'{version}/xnat-web-{version}.war">Download</a>'
            for repo, version in versions).encode()

    def check(self, installed="1.9.3.9", page=None):
        if page is None:
            page = self.release_page(("xnat-web", "1.9.3.9"), ("xnat", "1.10.2.1"))
        with patch.object(MONITOR, "http_get", side_effect=[
                (200, json.dumps({"version": installed}).encode()), (200, page)]):
            MONITOR.check_xnat_updates()
        return MONITOR.digest[-1][1]

    def test_current_maintenance_line_and_newer_release_line(self):
        summary = self.check()
        self.assertIn("Installed XNAT: 1.9.3.9", summary)
        self.assertIn("Latest stable in 1.9.x: 1.9.3.9 — up to date", summary)
        self.assertIn("Latest stable overall: 1.10.2.1 — UPDATE AVAILABLE", summary)
        self.assertEqual(MONITOR.issues, {})

    def test_four_part_hotfix_and_numeric_ordering(self):
        summary = self.check("1.9.3", self.release_page(
            ("xnat-web", "1.9.3.9"), ("xnat-web", "1.9.3.10")))
        self.assertIn("Latest stable in 1.9.x: 1.9.3.10 — UPDATE AVAILABLE", summary)

    def test_current_overall_release(self):
        summary = self.check("1.10.2.1")
        self.assertIn("Latest stable overall: 1.10.2.1 — up to date", summary)
        self.assertNotIn("UPDATE AVAILABLE", summary)

    def test_does_not_recommend_downgrade(self):
        summary = self.check("1.10.3")
        self.assertIn("installed version is newer", summary)
        self.assertNotIn("UPDATE AVAILABLE", summary)

    def test_unlisted_maintenance_line_is_not_claimed_current(self):
        summary = self.check("1.8.10.6")
        self.assertIn("Latest stable in 1.8.x: not listed", summary)

    def test_prereleases_plugins_and_unrelated_links_are_excluded(self):
        page = self.release_page(
            ("xnat-web", "1.9.3.9"), ("xnat", "1.10.3-rc1"))
        page += (b'<a href="https://github.com/other/xnat/releases/download/99.0/'
                 b'xnat-web-99.0.war">Other</a>'
                 b'<a href="https://github.com/NrgXnat/container-service/releases/download/'
                 b'99.0/container-service-99.0.jar">Plugin</a>')
        summary = self.check(page=page)
        self.assertIn("Latest stable overall: 1.9.3.9 — up to date", summary)

    def test_empty_or_malformed_release_feed_is_unknown(self):
        for page in (b"", b"<html>maintenance</html>"):
            with self.subTest(page=page):
                summary = self.check(page=page)
                self.assertIn("Installed XNAT: 1.9.3.9", summary)
                self.assertIn("Update status: UNKNOWN", summary)
                self.assertNotIn("up to date", summary)

    def test_network_errors_do_not_break_digest_or_health(self):
        for responses in ([TimeoutError("offline")], [
                (200, b'{"version":"1.9.3.9"}'), TimeoutError("offline")]):
            with self.subTest(responses=responses), patch.object(
                    MONITOR, "http_get", side_effect=responses):
                MONITOR.check_xnat_updates()
                self.assertIn("Update status: UNKNOWN", MONITOR.digest[-1][1])
                self.assertEqual(MONITOR.issues, {})

    def test_unrecognized_installed_version_is_unknown(self):
        for version in (None, "", "1.10.3-SNAPSHOT", "not-a-version"):
            with self.subTest(version=version):
                summary = self.check(installed=version)
                self.assertIn("Update status: UNKNOWN", summary)
                self.assertNotIn("up to date", summary)

    def test_digest_contains_update_section_and_only_checks_once_daily(self):
        with patch.object(MONITOR, "FORCE_DIGEST", False), \
                patch.object(MONITOR, "DIGEST_HOUR", MONITOR.LOCAL_NOW.hour), \
                patch.object(MONITOR, "http_get", side_effect=[
                    (200, b'{"version":"1.9.3.9"}'),
                    (200, self.release_page(("xnat", "1.10.2.1")))]) as get, \
                patch.object(MONITOR, "send_email") as send:
            MONITOR.maybe_send_digest()
            self.assertIn("XNAT updates\n", send.call_args.args[1])
            self.assertIn("1.10.2.1 — UPDATE AVAILABLE", send.call_args.args[1])
            MONITOR.maybe_send_digest()
            self.assertEqual(get.call_count, 2)
            send.assert_called_once()

    def test_no_upstream_lookup_outside_digest_hour(self):
        with patch.object(MONITOR, "FORCE_DIGEST", False), \
                patch.object(MONITOR, "DIGEST_HOUR", (MONITOR.LOCAL_NOW.hour + 1) % 24), \
                patch.object(MONITOR, "http_get") as get, \
                patch.object(MONITOR, "send_email") as send:
            MONITOR.maybe_send_digest()
            get.assert_not_called()
            send.assert_not_called()


class SecurityEmailTest(unittest.TestCase):
    def setUp(self):
        MONITOR.digest = []
        MONITOR.issues = {}
        MONITOR.state = {"alerts": {}}

    def test_missing_or_corrupt_report_does_not_break_digest(self):
        with patch.object(MONITOR, "FORCE_DIGEST", True), \
                patch.object(MONITOR, "check_xnat_updates"), \
                patch.object(MONITOR, "send_email") as send, \
                patch("builtins.open", side_effect=FileNotFoundError("missing")):
            MONITOR.maybe_send_digest()
        subject, body = send.call_args.args
        self.assertIn("security scan incomplete", subject)
        self.assertNotIn("all OK", subject)
        self.assertIn("Important CVEs", body)
        self.assertIn("CVE status: UNKNOWN", body)

    def test_security_actions_appear_in_subject(self):
        with patch.object(MONITOR, "FORCE_DIGEST", True), \
                patch.object(MONITOR, "check_xnat_updates"), \
                patch.object(MONITOR, "check_security_advisories", return_value="security actions required"), \
                patch.object(MONITOR, "send_email") as send:
            MONITOR.maybe_send_digest()
        self.assertIn("security actions required", send.call_args.args[0])
        self.assertNotIn("all OK", send.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
