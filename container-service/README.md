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
- `commands/fmriprep-session.json` - local `xnat/fmriprep:25.2.5-ais.2`
  participant-level fMRIPrep command through `xnat2bids`, enabled site-wide for
  `xnat:mrSessionData`. Build it before installing the commands with
  `./scripts/build-fmriprep-image.sh`. The image extends
  `nipreps/fmriprep:25.2.5` with the public FreeSurfer license embedded by
  Neurodesk's pinned FreeSurfer recipe. The build verifies the payload checksum
  and fMRIPrep's own license check; the license text is not stored in this
  repository.
- `commands/aslprep-session.json` - `pennlinc/aslprep:26.0.3`
  participant-level ASLPrep command through `xnat2bids`, enabled site-wide for
  `xnat:mrSessionData`.
- `commands/qsmxt-session.json` - Neurodesk `vnmd/qsmxt_9.22.0:20260923`
  session-level QSMxT command with internal DICOM-to-BIDS conversion, enabled site-wide for
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
and `MUSCLEMAP`. QSMxT converts session DICOMs internally. For the other BIDS apps, run DICOM
to BIDS first or provide matching scan-level `NIFTI` and `BIDS` resources.
fMRIPrep and ASLPrep run with `--fs-no-reconall` by default. fMRIPrep 25.2.5
still performs an unconditional FreeSurfer license validation, so its local
image includes the public license from Neurodesk's FreeSurfer recipe. QSMxT
converts the session's magnitude/phase DICOMs to BIDS in writable work storage
and uploads the generated derivatives to the session's `QSMXT` resource.

QSMxT's **Pipeline preset** dropdown matches the OpenRecon algorithm presets.
Choose `custom` to set **QSM algorithm**, **Unwrap**, and **Background removal**
individually (defaults: HD-QSM, ROMEO, iSMV). Presets override these three
controls. BET and magnitude are the default mask settings; legacy `gre`, `epi`,
`bet`, `fast`, and `body` presets retain their previous mask/algorithm choices.

**Generate SWI**, **Generate T2* map**, and **Generate R2* map** default to on.
T2*/R2* fitting needs at least three equally spaced magnitude echoes. QSMxT
computes both fitted maps when either fitting option is enabled. A requested
output that cannot be generated produces a warning in the container log.
`*_part-mag_T2starw.nii` is the combined magnitude image with T2* contrast;
it is not a quantitative relaxation map. `*_T2starmap.nii` contains seconds,
and `*_R2starmap.nii` contains inverse seconds. SWI uses magnitude and phase. Its `minIP` is a sliding seven-slice minimum
projection: an input with 144 slices produces 138 projected slices, positioned
at their slab centres. QSMxT 9.19.1–9.21.x wrote malformed minIP headers
(QSMxT#211, fixed in 9.22.0); the wrapper reads every minIP's full payload
and drops any malformed one before upload.

QSMxT 9.22.0 adds, all selectable at launch:

- **Generate SMWI** (default on): susceptibility map-weighted imaging, which
  weights the magnitude by a mask built from the susceptibility map so contrast
  stays at the source. Writes `desc-paramagnetic_smwi` and
  `desc-diamagnetic_smwi`, each with its own `minIP`.
- **Generate R2' map** with **R2' source**: `auto` measures R2' = R2* - R2 from
  a multi-echo spin-echo scan in the session, and otherwise predicts it with
  R2PRIMEnet; `mese` only measures; `r2primenet` always predicts. A prediction
  is an estimate, not a measurement.
- **Two-pass artefact reduction**: a second reconstruction on a mask that keeps
  holes at strong sources (air-tissue interfaces, haemorrhage, implants). It
  roughly doubles run time; the single-pass map is kept as
  `desc-singlepass_Chimap`.
- **Segment brain (SynthSeg)**: whole-brain FreeSurfer labels from the GRE
  magnitude (`dseg.nii` plus its `dseg.tsv` label table), with no T1w or
  registration. **Per-structure susceptibility statistics** adds median, mean,
  SD and 5th/95th percentiles per structure (`desc-segmentation_qsmstats.tsv`)
  and implies segmentation.
- **QSM algorithm** gains LSQR and HEIDI; **Mask preset** gains Combined
  (`bet-and-phase`, BET on the magnitude intersected with a thresholded
  phase-quality map) and HD-BET.

The SynthSeg and R2PRIMEnet weights ship in the image, so runs need no network.

The scan-link sync runs every 15 minutes and links generated maps to the source
phase scan as `QSM` (including a two-pass run's single-pass map), `SWI`
(including its minIP), `SMWI` (both SMWI images and their minIPs), `T2STAR`,
`R2STAR`, `R2PRIME`, and `SEG` (segmentation with its label table) resources. The session resource retains all derivatives. Existing
runs must be rerun to generate maps that were previously disabled.

Regression checks: `python3 -m unittest discover -s tests -p 'test_qsmxt*.py'`.
For numerical validation against known T2*/R2* values, run the synthetic
phantom in the installed image:

```bash
sudo docker run --rm --network none --cpus 4 --memory 4g \
  -v "$PWD:/repo:ro" --entrypoint bash vnmd/qsmxt_9.22.0:20260923 \
  -lc 'python3 -m unittest discover -s /repo/tests -p "test_qsmxt*.py" && python3 /repo/tests/qsmxt_phantom.py'
```


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
