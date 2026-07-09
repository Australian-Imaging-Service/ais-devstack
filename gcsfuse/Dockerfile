FROM google/cloud-sdk:slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    fuse3 \
    gnupg \
    lsb-release \
    procps \
  && export GCSFUSE_REPO="gcsfuse-$(lsb_release -c -s)" \
  && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt ${GCSFUSE_REPO} main" \
    > /etc/apt/sources.list.d/gcsfuse.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends gcsfuse \
  && sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf \
  && rm -rf /var/lib/apt/lists/*

COPY mount-gcs.sh /usr/local/bin/mount-gcs.sh
RUN chmod +x /usr/local/bin/mount-gcs.sh

ENTRYPOINT ["/usr/local/bin/mount-gcs.sh"]
