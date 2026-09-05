import importlib.util
import os
import sys
import tempfile
import types
import unittest
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


if __name__ == "__main__":
    unittest.main()
