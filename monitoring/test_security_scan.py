import copy
import fcntl
from datetime import datetime, timedelta, timezone
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import security_scan
from security_scan import collect_findings, image_targets, important_findings, security_summary


NOW = datetime(2026, 11, 13, tzinfo=timezone.utc)


def finding(**values):
    return {"id": "CVE-2026-10001", "severity": "HIGH", "package": "example",
            "installed": "1.0", "fixed": "1.1", "target": "xnat",
            "title": "Example vulnerability", "url": "https://example.invalid/advisory",
            **values}


def report():
    return {"schema_version": 1, "started_at": NOW.isoformat(),
            "completed_at": NOW.isoformat(), "database_updated_at": NOW.isoformat(),
            "kev_released_at": NOW.isoformat(), "errors": [], "important": [],
            "total_targets": 3, "scanned_targets": 3, "unfixed_high_critical": 0}


class SecurityPrioritiesTest(unittest.TestCase):
    def test_only_fixable_high_critical_and_known_exploited_are_prioritized(self):
        items = [finding(), finding(id="CVE-2026-10002", severity="LOW", fixed=""),
                 finding(id="CVE-2026-10003", severity="MEDIUM"),
                 finding(id="CVE-2026-10004", severity="HIGH", fixed=""),
                 finding(id="CVE-2026-10005", severity="CRITICAL")]
        kev = {"CVE-2026-10002": {"requiredAction": "Apply mitigations"}}
        selected = important_findings(items, kev)
        self.assertEqual([item["id"] for item in selected],
                         ["CVE-2026-10002", "CVE-2026-10005", "CVE-2026-10001"])

    def test_deduplication_preserves_targets_and_distinct_affected_versions(self):
        selected = important_findings([
            finding(), finding(target="postgres"), finding(target="postgres"),
            finding(installed="0.9")], {})
        self.assertEqual(len(selected), 2)
        self.assertEqual(selected[0]["targets"], ["xnat", "postgres"])

    def test_standalone_and_kubernetes_reports_keep_real_package_matches(self):
        vulnerability = {"VulnerabilityID": "CVE-2026-10001", "PkgName": "library",
                         "InstalledVersion": "1.0", "FixedVersion": "1.1", "Severity": "CRITICAL"}
        results = [{"Target": "actual-image", "Vulnerabilities": [vulnerability]}]
        for document in ({"Results": results}, {"Resources": [{"Results": results}]}):
            with self.subTest(document=document):
                matches = collect_findings(document, "deployment")
                self.assertEqual(matches[0]["package"], "library")
                self.assertEqual(matches[0]["fixed"], "1.1")
                self.assertEqual(matches[0]["target"], "deployment")

    def test_vendor_not_affected_is_excluded(self):
        document = {"Results": [{"Vulnerabilities": [{
            "Status": "not_affected"}]}]}
        self.assertEqual(collect_findings(document, "test"), [])


class SecurityDigestTest(unittest.TestCase):
    def test_complete_scan_without_matches_has_scoped_language(self):
        summary = security_summary(report(), NOW)
        self.assertIn("No prioritized CVEs found in the scanned inventory", summary)
        self.assertIn("Coverage: 3/3", summary)

    def test_stale_scan_is_never_an_all_clear(self):
        data = report()
        data["started_at"] = (NOW - timedelta(hours=31)).isoformat()
        summary = security_summary(data, NOW)
        self.assertTrue(summary.startswith("INCOMPLETE"))
        self.assertIn("STALE", summary)
        self.assertNotIn("No prioritized CVEs", summary)

    def test_failed_target_missing_kev_and_old_database_are_explicit(self):
        data = report()
        data["errors"] = ["image inaccessible", "CISA known-exploited feed unavailable"]
        data["database_updated_at"] = (NOW - timedelta(days=3)).isoformat()
        data["scanned_targets"] = 2
        summary = security_summary(data, NOW)
        self.assertIn("INCOMPLETE", summary)
        self.assertIn("2/3 targets", summary)
        self.assertIn("CISA known-exploited feed unavailable", summary)
        self.assertIn("database is older than 48 hours", summary)

    def test_missing_coverage_cannot_claim_no_prioritized_cves(self):
        data = report()
        data["scanned_targets"] = 0
        summary = security_summary(data, NOW)
        self.assertTrue(summary.startswith("INCOMPLETE"))
        self.assertNotIn("No prioritized CVEs", summary)

    def test_known_exploited_findings_include_mitigation_without_a_fix(self):
        data = report()
        data["important"] = important_findings([finding(fixed="", severity="MEDIUM")],
            {"CVE-2026-10001": {"requiredAction": "Disable affected feature"}})
        summary = security_summary(data, NOW)
        for text in ("ACTION REQUIRED", "KNOWN EXPLOITED", "no published fix",
                     "Disable affected feature", "Affected: xnat", "https://example.invalid/advisory"):
            self.assertIn(text, summary)

    def test_digest_truncation_points_to_complete_report(self):
        data = report()
        data["important"] = important_findings([
            finding(id=f"CVE-2026-{10000+i}") for i in range(4)], {})
        summary = security_summary(data, NOW, limit=2)
        self.assertIn("2 additional prioritized CVEs", summary)
        self.assertIn("security-report.json", summary)

    def test_one_cve_is_not_repeated_for_each_affected_package(self):
        data = report()
        data["important"] = important_findings([
            finding(), finding(package="second-package", target="host")], {})
        summary = security_summary(data, NOW)
        self.assertEqual(summary.count("CVE-2026-10001 ["), 1)
        self.assertIn("Package: example 1.0", summary)
        self.assertIn("Package: second-package 1.0", summary)
        self.assertIn("Affected: host; xnat", summary)

    def test_corrupt_or_future_report_is_not_treated_as_current(self):
        for update in ({"schema_version": 2}, {"completed_at": "invalid"},
                       {"completed_at": (NOW + timedelta(days=1)).isoformat()}):
            with self.subTest(update=update):
                data = {**report(), **update}
                with self.assertRaises(ValueError):
                    security_summary(data, NOW)


class SecurityInventoryTest(unittest.TestCase):
    def test_absolute_host_runtime_symlink_stays_inside_host_bind(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory) / "var/lib/rancher/k3s/data"
            parent.mkdir(parents=True)
            (parent / "current").symlink_to("/var/lib/rancher/k3s/data/pinned-release")
            with patch.object(security_scan, "HOST", directory):
                self.assertEqual(security_scan.host_runtime_directory(),
                                 str(parent / "pinned-release/bin"))

    def test_missing_runtime_blobs_can_fall_back_to_exact_registry_digest(self):
        target = {"runtime": "containerd", "ref": "registry/app@sha256:123"}
        with patch.object(security_scan, "run_trivy", side_effect=[RuntimeError("missing blob"), {}]) as run:
            security_scan.scan_target(target, Path("unused"))
        self.assertEqual(run.call_args.args[0], ["image", "--image-src", "remote",
                                                "--scanners", "vuln", "registry/app@sha256:123"])
        self.assertTrue(target["registry_fallback"])

    def test_mutable_local_image_cannot_fall_back_to_different_registry_image(self):
        target = {"runtime": "containerd", "ref": "registry/app:latest"}
        with patch.object(security_scan, "run_trivy", side_effect=RuntimeError("missing blob")) as run:
            with self.assertRaises(RuntimeError):
                security_scan.scan_target(target, Path("unused"))
        run.assert_called_once()

    def test_local_tag_mismatch_is_explicitly_incomplete(self):
        target = {"runtime": "containerd", "ref": "local:latest", "expected_id": "sha256:running"}
        with patch.object(security_scan, "run_trivy", return_value={"Metadata": {"ImageID": "sha256:other"}}):
            with self.assertRaisesRegex(ValueError, "no longer matches"):
                security_scan.scan_target(target, Path("unused"))

    def test_overlapping_manual_scan_skips_without_inventory_or_report_write(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "security-report.json")
            with Path(path).with_suffix(".lock").open("w") as existing:
                fcntl.flock(existing, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with patch.object(security_scan, "REPORT_FILE", path), \
                        patch.object(security_scan, "api_get") as api, \
                        patch.object(security_scan, "write_report") as write:
                    self.assertEqual(security_scan.main(), 0)
                    api.assert_not_called()
                    write.assert_not_called()

    def test_running_digest_scheduled_jobs_and_docker_are_included(self):
        pod = {"metadata": {"namespace": "test", "name": "app"},
               "spec": {"nodeName": "node", "containers": [{"name": "web", "image": "app:latest"}]},
               "status": {"phase": "Running", "containerStatuses": [{
                   "name": "web", "imageID": "registry/app@sha256:123"}]}}
        scheduled = {"metadata": {"namespace": "test", "name": "backup"}, "spec": {
            "jobTemplate": {"spec": {"template": {"spec": {"containers": [{"image": "backup:v1"}]}}}}}}
        docker = {"ImageID": "sha256:456", "Names": ["pipeline"]}
        targets = image_targets([pod], [scheduled], [docker], "node")
        self.assertEqual({item["ref"] for item in targets},
                         {"registry/app@sha256:123", "docker.io/library/backup:v1", "sha256:456"})
        suspended = copy.deepcopy(scheduled)
        suspended["spec"]["suspend"] = True
        self.assertEqual(image_targets([], [suspended], [], "node"), [])

    def test_unscanned_remote_node_cannot_silently_disappear(self):
        pod = {"metadata": {"name": "remote"}, "spec": {"nodeName": "other"},
               "status": {"phase": "Running"}}
        with self.assertRaisesRegex(ValueError, "unscanned node"):
            image_targets([pod], [], [], "node")


if __name__ == "__main__":
    unittest.main()
