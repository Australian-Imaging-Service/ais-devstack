FROM google/cloud-sdk:slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    gnupg \
    unzip \
    postgresql-client \
  && rm -rf /var/lib/apt/lists/* \
  && gcloud storage --help >/dev/null

COPY xnat-archive-to-gcs.sh /usr/local/bin/xnat-archive-to-gcs.sh
RUN chmod +x /usr/local/bin/xnat-archive-to-gcs.sh

ENTRYPOINT ["/usr/local/bin/xnat-archive-to-gcs.sh"]
