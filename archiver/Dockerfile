FROM google/cloud-sdk:slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    gnupg \
    unzip \
  && echo "deb http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
     > /etc/apt/sources.list.d/pgdg.list \
  && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
     | gpg --dearmor -o /etc/apt/trusted.gpg.d/pgdg.gpg \
  && apt-get update \
  && apt-get install -y --no-install-recommends postgresql-client-16 \
  && rm -rf /var/lib/apt/lists/*

COPY xnat-archive-to-gcs.sh /usr/local/bin/xnat-archive-to-gcs.sh
RUN chmod +x /usr/local/bin/xnat-archive-to-gcs.sh

ENTRYPOINT ["/usr/local/bin/xnat-archive-to-gcs.sh"]
