# Platform monitor

The `platform-monitor` CronJob checks system health every 15 minutes and sends
a daily digest at 08:00 America/Los_Angeles. SMTP credentials remain in the
existing `platform-monitor-smtp` Kubernetes Secret.

The daily email includes an **XNAT updates** section with:

- The running application's version from `/xapi/siteConfig/buildInfo`.
- The latest stable version in the installed release line (for example, 1.9.x),
  including four-part maintenance/security hotfix versions.
- The latest stable XNAT version overall, with `UPDATE AVAILABLE` when newer.
- The check time and a link to downloads and release notes.

Releases are read from core WAR links on the [official download page](https://www.xnat.org/download/).
Plugins and prereleases are excluded. The lookup runs only when a daily digest
is due, including `FORCE_DIGEST=1` runs. Failed lookups produce an explicit
`UNKNOWN` update status in the email and do not interrupt the digest or become
platform health alerts. Update availability is informational; upgrades remain
manual and require checking release notes and plugin compatibility.

Run tests with `python3 -m unittest discover -s monitoring -p 'test_*.py'`.
Install or update the monitor with `./scripts/install-platform-monitor.sh`;
this builds/imports the image and applies `manifests/platform-monitor.yaml`.
It preserves the existing SMTP secret unless `SMTP_PASSWORD` is supplied.

## Important CVEs

The daily email also includes an **Important CVEs** section. A separate
`platform-security-scan` CronJob runs at 04:00 America/Los_Angeles, ahead of
the 08:00 digest. It uses Trivy 0.76.2 (image pinned by digest), refreshed
vulnerability databases, and CISA's known exploited vulnerabilities catalog.

Coverage includes running Kubernetes images across all namespaces, images in
enabled CronJobs (including their init containers), running Docker pipeline
images, host OS packages, k3s/containerd/Docker binaries, Kubernetes component versions, and
the mounted XNAT plugin directory. Running registry images are scanned by digest.
Local-only image tags are checked against their running image IDs. Each report
records image references and owning workloads. No software is upgraded.

The digest prioritizes version-matched findings that are either known exploited
(regardless of severity or fix availability), or High/Critical with a published
fix. It lists the CVE, affected package/version and workloads, fixed versions,
vendor advisory, and remediation. Known exploited items come first. The email
shows up to 20 distinct CVEs, grouping affected packages/versions and workloads, identifies additional
findings, and counts High/Critical occurrences without a published fix.

The full inventory, all matched findings, prioritized findings, and errors are
saved atomically to `/srv/xnat-local-storage/monitoring/security-report.json`.
The digest explicitly flags unavailable reports, scans older than 30 hours,
databases older than 48 hours, failed scans/inventory collection, and missing
or stale CISA data. Security actions and incomplete scans appear in the email
subject even when ordinary platform health is good.

The scanner has read-only Kubernetes access and a read-only host bind; it reads
the local container runtime sockets to inspect images. It does not scan secrets
or patient archives. Runtime socket access is powerful, so the scanner is pinned
and is separate from the monitor's SMTP/database credentials. CPU and memory are
limited, runs cannot overlap, and each run has a three-hour deadline. Its database
cache persists under the monitor state directory.

Coverage is a snapshot of this cluster/node. It excludes remote edge hosts,
stopped ad-hoc images, and software unsupported by the scanner. A package match
requires checking actual exposure before remediation; it does not prove that
the deployed service is exploitable. XNAT's own version/update check remains
useful alongside dependency scanning, since not every vendor advisory has a
machine-readable package match.

Run a scan manually:

```bash
sudo kubectl -n ais-xnat create job --from=cronjob/platform-security-scan platform-security-manual-$(date +%s)
```

The deployed monitor/scanner image is `xnat-platform-monitor:security-digest-20261113`.
