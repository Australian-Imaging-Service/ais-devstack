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
- `commands/dcm2niix-scan.json` - XNAT's `xnat/dcm2niix:1.6` scan- and
  session-level converter. The `dcm2niix-scan` wrapper converts one scan's
  `DICOM` resource into a scan resource labeled `NIFTI`. The
  `dcm2niix-session` wrapper recursively converts every DICOM series in an MR
  session into a session resource labeled `NIFTI`. BIDS JSON sidecars are
  enabled by default for both wrappers.
- `commands/mriqc-session.json` - `nipreps/mriqc:24.0.2` participant-level
  MRIQC command, enabled site-wide for `xnat:mrSessionData`.
- `commands/fmriprep-session.json` - `nipreps/fmriprep:25.2.5`
  participant-level fMRIPrep command through `xnat2bids`, enabled site-wide for
  `xnat:mrSessionData`.
- `commands/aslprep-session.json` - `pennlinc/aslprep:26.0.3`
  participant-level ASLPrep command through `xnat2bids`, enabled site-wide for
  `xnat:mrSessionData`.
- `commands/qsmxt-session.json` - Neurodesk `vnmd/qsmxt_8.3.2:20260421`
  session-level QSMxT command through `xnat2bids`, enabled site-wide for
  `xnat:mrSessionData`.
- `commands/musclemap-scan.json` - Neurodesk `vnmd/musclemap_1.3.45:20260701`
  scan-level and session-level MuscleMap wrappers. They run on the first NIfTI
  file in a scan's `NIFTI` resource or xnat2bids-staged MR session and store
  outputs in a resource labeled `MUSCLEMAP`.
- `commands/spinalcordtoolbox-scan.json` - Neurodesk
  `vnmd/spinalcordtoolbox_7.3.0:20260605` scan-level `sct_deepseg` wrapper. It
  runs on the first NIfTI file in a scan's `NIFTI` resource and stores outputs
  in a scan resource labeled `SCT`.

MRIQC, fMRIPrep, ASLPrep, QSMxT, and session-level MuscleMap store outputs back
on the session as resources labeled `MRIQC`, `FMRIPREP`, `ASLPREP`, `QSMXT`,
and `MUSCLEMAP`. They do not convert raw DICOM into BIDS. Run DICOM to BIDS
first, or otherwise provide matching scan-level `NIFTI` and `BIDS` resources.
fMRIPrep and ASLPrep run with `--fs-no-reconall` by default so no FreeSurfer
license secret is required by these wrappers. QSMxT expects BIDS-compatible QSM
inputs, typically `part-mag` and `part-phase` `T2starw` files with JSON
sidecars; it copies the staged BIDS dataset to writable work storage and
uploads the generated `derivatives`.

Scan-level MuscleMap and Spinal Cord Toolbox require scan-level `NIFTI`
resources. If a `NIFTI` resource contains multiple NIfTI files, the wrappers
process the first `.nii` or `.nii.gz` file in lexical order.

The Container Service plugin jar is patched so Docker launches also bind-mount
`/data/xnat/object-store` read-only when that path exists. Scan-level wrappers
can follow archived-file symlinks into the object store without rehydrating
files, as long as the host-side `/data/xnat/object-store` mirror points to the
mounted object-store directory.

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
