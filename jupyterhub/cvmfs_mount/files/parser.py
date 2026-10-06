#!/usr/bin/env python3
"""
CVMFS Trace Parser for ais-jupyterhub
Parses CVMFS trace files and exposes metrics in Prometheus format.
Adapted from neurocloud implementation.
"""
import csv
import re
import subprocess
import time
import os
import requests
from collections import deque, defaultdict
from http.server import HTTPServer, BaseHTTPRequestHandler
import threading

NAMESPACE = os.environ.get('NAMESPACE', 'mounts')

class TraceParser:
    def __init__(self):
        self.flush_markers = deque(maxlen=10)
        self.module_counts = defaultdict(int)
        self.total_flush_count = 0
        self.last_parsed_line = 0  # Track where we left off to avoid double-counting

    def flush_cvmfs_buffer(self, repo):
        try:
            cmd = f"kubectl exec -n {NAMESPACE} $(kubectl get pods -n {NAMESPACE} -l app=cvmfs-csi,component=nodeplugin -o name | head -1 | cut -d/ -f2) -c automount -- cvmfs_talk -i {repo} tracebuffer flush"
            subprocess.run(cmd, shell=True, check=True, capture_output=True)
            print(f"Flushed buffer for {repo}")
        except subprocess.CalledProcessError as e:
            print(f"Failed to flush buffer for {repo}: {e}")

    def wipe_trace_file(self, repo):
        """Wipe the contents of the trace file without deleting it"""
        try:
            cmd = f"kubectl exec -n {NAMESPACE} $(kubectl get pods -n {NAMESPACE} -l app=cvmfs-csi,component=nodeplugin -o name | head -1 | cut -d/ -f2) -c automount -- sh -c 'true > /tmp/cvmfs-trace-{repo}.log'"
            subprocess.run(cmd, shell=True, check=True, capture_output=True)
            print(f"Wiped trace file for {repo}")
            self.total_flush_count = 0  # Reset counter after wiping
            self.last_parsed_line = 0  # Reset line tracking after wiping
        except subprocess.CalledProcessError as e:
            print(f"Failed to wipe trace file for {repo}: {e}")

    def get_trace_file_content(self, repo):
        try:
            cmd = f"kubectl exec -n {NAMESPACE} $(kubectl get pods -n {NAMESPACE} -l app=cvmfs-csi,component=nodeplugin -o name | head -1 | cut -d/ -f2) -c automount -- cat /tmp/cvmfs-trace-{repo}.log"
            result = subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True)
            return result.stdout.strip().split('\n') if result.stdout.strip() else []
        except subprocess.CalledProcessError as e:
            print(f"Failed to get trace file for {repo}: {e}")
            return []

    def parse_trace_file(self, repo):
        # Disabled forced flush - let CVMFS auto-flush at threshold to avoid blocking I/O
        # self.flush_cvmfs_buffer(repo)
        self.total_flush_count += 1

        lines = self.get_trace_file_content(repo)
        if not lines:
            return

        current_flush_markers = []
        for i, line in enumerate(lines):
            if line and '"Tracer","flushed ring buffer"' in line:
                current_flush_markers.append(i)

        if current_flush_markers:
            self.flush_markers.extend(current_flush_markers)

        if len(self.flush_markers) >= 2:
            start_line = self.flush_markers[-2]
            end_line = self.flush_markers[-1]
            # Only parse if this segment hasn't been parsed yet
            if end_line > self.last_parsed_line:
                self.parse_segment(lines[start_line:end_line], repo)
                self.last_parsed_line = end_line

        # Also parse unflushed data from last marker to EOF
        start_pos = max(self.flush_markers[-1] + 1 if self.flush_markers else 0, self.last_parsed_line)
        if start_pos < len(lines):
            self.parse_segment(lines[start_pos:], repo)
            self.last_parsed_line = len(lines)

        if self.total_flush_count >= 1000:
            print(f"Reached {self.total_flush_count} flushes, wiping trace file...")
            self.wipe_trace_file(repo)
            self.flush_markers.clear()

    def parse_segment(self, lines, repo):
        i = 0
        new_opens = defaultdict(int)

        while i < len(lines) - 1:
            try:
                if not lines[i].strip():
                    i += 1
                    continue

                current = list(csv.reader([lines[i]]))[0]
                if len(current) < 4:
                    i += 1
                    continue

                if current[1] == "1" and "/containers/" in current[2] and current[3] == "open()":
                    if i + 1 < len(lines) and lines[i + 1].strip():
                        next_line = list(csv.reader([lines[i + 1]]))[0]
                        if (len(next_line) >= 4 and
                            next_line[1] == "4" and
                            "/containers/" in next_line[2] and
                            next_line[3] == "lookup()" and next_line[2].endswith("/singularity")):

                            module_match = re.search(r'/containers/([^/]+)/', current[2])
                            if module_match:
                                module = module_match.group(1)
                                new_opens[module] += 1
                                print(f"Found module open: {module}")

                            i += 2
                            continue

                i += 1

            except (csv.Error, IndexError) as e:
                print(f"Error parsing line {i}: {e}")
                i += 1

        for module, count in new_opens.items():
            self.module_counts[module] += count
            print(f"Module {module}: +{count} opens (total: {self.module_counts[module]})")

    def get_prometheus_metrics(self):
        metrics = []
        metrics.append("# HELP cvmfs_module_opens_total Total number of module opens")
        metrics.append("# TYPE cvmfs_module_opens_total counter")

        for module, count in self.module_counts.items():
            metrics.append(f'cvmfs_module_opens_total{{module="{module}"}} {count}')

        return '\n'.join(metrics)

class MetricsServer:
    def __init__(self, parser):
        self.parser = parser

    def get_telegraf_metrics(self):
        try:
            response = requests.get("http://localhost:9001/metrics", timeout=5)
            if response.status_code == 200:
                return response.text
            else:
                return ""
        except Exception as e:
            print(f"Error fetching telegraf metrics: {e}")
            return ""

    def start_server(self):
        class MetricsHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == '/metrics':
                    metrics = []

                    trace_metrics = self.server.parser.get_prometheus_metrics()
                    if trace_metrics:
                        metrics.append(trace_metrics)

                    telegraf_metrics = self.server.metrics_server.get_telegraf_metrics()
                    if telegraf_metrics:
                        metrics.append(telegraf_metrics)

                    response = '\n'.join(metrics)

                    self.send_response(200)
                    self.send_header('Content-Type', 'text/plain')
                    self.end_headers()
                    self.wfile.write(response.encode())
                else:
                    self.send_response(404)
                    self.end_headers()

            def log_message(self, format, *args):
                pass

        server = HTTPServer(('0.0.0.0', 9002), MetricsHandler)
        server.parser = self.parser
        server.metrics_server = self

        print("Combined metrics server started on port 9002")
        server.serve_forever()

def main():
    parser = TraceParser()
    metrics_server = MetricsServer(parser)

    server_thread = threading.Thread(target=metrics_server.start_server, daemon=True)
    server_thread.start()

    print("Waiting for telegraf to start...")
    time.sleep(10)

    repos = ["neurodesk.ardc.edu.au"]

    while True:
        for repo in repos:
            try:
                print(f"Parsing {repo}...")
                parser.parse_trace_file(repo)
            except Exception as e:
                print(f"Error parsing {repo}: {e}")

        print("Sleeping 30 seconds...")
        time.sleep(30)

if __name__ == "__main__":
    main()
