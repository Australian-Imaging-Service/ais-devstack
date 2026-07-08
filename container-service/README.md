# XNAT Container Service Commands

This directory contains command definitions that are loaded into XNAT Container
Service with scripts in `../scripts`.

## MRIQC

Install or update the MRIQC command definitions:

```bash
./scripts/install-mriqc-container-service.sh
```

The installer loads:

- `commands/xnat2bids-setup.json` - setup command that converts an XNAT session
  with scan-level `NIFTI` resources and `BIDS` JSON sidecar resources into a
  BIDS directory.
- `commands/mriqc-session.json` - `nipreps/mriqc:24.0.2` participant-level
  MRIQC command, enabled site-wide for `xnat:mrSessionData`.

The command stores outputs back on the session as a resource labeled `MRIQC`.
It does not convert raw DICOM into BIDS. Sessions must already have matching
scan-level `NIFTI` and `BIDS` resources before MRIQC will produce useful output.
