FROM aquasec/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb AS scanner

FROM python:3.12-alpine

RUN pip install --no-cache-dir pg8000 tzdata

COPY --from=scanner /usr/local/bin/trivy /usr/local/bin/trivy
COPY platform-monitor.py security_scan.py /usr/local/bin/

ENTRYPOINT ["python", "/usr/local/bin/platform-monitor.py"]
