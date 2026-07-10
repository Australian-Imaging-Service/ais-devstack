FROM python:3.12-alpine

RUN pip install --no-cache-dir pg8000 tzdata

COPY platform-monitor.py /usr/local/bin/platform-monitor.py

ENTRYPOINT ["python", "/usr/local/bin/platform-monitor.py"]
