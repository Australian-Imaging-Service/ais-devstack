# XNAT Container Service Commands

This directory contains command definitions that are loaded into XNAT Container
Service with scripts in `../scripts`.

## Install

Install or update the Container Service command definitions:

```bash
./scripts/install-mriqc-container-service.sh
```

The installer loads:

- `commands/xnat2bids-setup.json` - setup command that converts an XNAT session
  with scan-level `NIFTI` resources and `BIDS` JSON sidecar resources into a
  BIDS directory.
- `commands/dcm2bids-session.json` - XNAT's `xnat/dcm2bids-session:1.5.1`
  converter. It converts scan-level `DICOM` resources into scan-level `NIFTI`
  resources and `BIDS` JSON sidecars using the site or project BIDS map.
- `commands/mriqc-session.json` - `nipreps/mriqc:24.0.2` participant-level
  MRIQC command, enabled site-wide for `xnat:mrSessionData`.

MRIQC stores outputs back on the session as a resource labeled `MRIQC`. MRIQC
does not convert raw DICOM into BIDS. Run DICOM to BIDS first, or otherwise
provide matching scan-level `NIFTI` and `BIDS` resources.

Install or update the site-wide BIDS map used by DICOM to BIDS:

```bash
./scripts/install-bidsmap.sh
```

The source map is `bidsmap/site-bidsmap.json`. XNAT's dcm2bids container uses
exact, case-insensitive `series_description` matches; add project-specific maps
for protocols that need different task labels or modality names.

By default the installer enables wrappers site-wide and for every current
project. Set `CONTAINER_SERVICE_ENABLE_PROJECTS=none` to skip project-level
enablement, or set it to a comma-separated project list to enable only selected
projects.

Apply `../manifests/container-service-project-sync.yaml` to keep the wrappers
enabled for future projects:

```bash
sudo kubectl apply -f manifests/container-service-project-sync.yaml
```

The sync CronJob uses the existing `xnat-archiver-creds` Kubernetes secret and
runs every 15 minutes. It does not store credentials in git.
