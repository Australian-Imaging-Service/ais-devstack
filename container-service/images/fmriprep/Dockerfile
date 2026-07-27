ARG BASE_IMAGE=nipreps/fmriprep:25.2.5
FROM ${BASE_IMAGE}

ARG FREESURFER_LICENSE_SHA256

USER root
COPY license.txt /opt/freesurfer/license.txt
RUN chmod 0444 /opt/freesurfer/license.txt \
    && echo "${FREESURFER_LICENSE_SHA256}  /opt/freesurfer/license.txt" | sha256sum -c -

ENV FS_LICENSE=/opt/freesurfer/license.txt

LABEL org.opencontainers.image.title="AIS fMRIPrep with Neurodesk FreeSurfer license" \
      org.opencontainers.image.base.name="nipreps/fmriprep:25.2.5" \
      org.opencontainers.image.source="https://github.com/neurodesk/neurocontainers/tree/main/recipes/freesurfer"
