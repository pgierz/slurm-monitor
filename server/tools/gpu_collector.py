#!/usr/bin/env python3
"""Per-node GPU metrics collector for nodes without a DCGM exporter.

Single file, standard library only, Python 3.6+ syntax. Serves

    GET /metrics.json
    {"node": "<short hostname>",
     "cards": [{"index": 0, "utilisation": 0.97, "memory_used_mib": 36864,
                "memory_total_mib": 40960, "temperature_c": 74, "power_w": 286}]}

nvidia-smi is run at most once per --interval seconds; requests in between
are answered from the cache. If nvidia-smi is missing or fails the answer is
HTTP 503 with {"error": "nvidia_smi_unavailable", "detail": "..."}.
"""

import argparse
import json
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

QUERY = "index,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw"
FIELD_COUNT = 6


class CollectorError(Exception):
    pass


def _number(text):
    """nvidia-smi value to float; `[N/A]`, `[Not Supported]` and the like to None."""
    text = text.strip()
    try:
        return float(text)
    except ValueError:
        return None


def _rounded(value):
    return None if value is None else int(round(value))


def parse_nvidia_smi(output):
    """Parse `--format=csv,noheader,nounits` output into the list of cards."""
    cards = []
    for line in output.splitlines():
        if not line.strip():
            continue
        fields = [f.strip() for f in line.split(",")]
        if len(fields) != FIELD_COUNT:
            raise CollectorError("unexpected nvidia-smi line: %r" % line)
        index = _number(fields[0])
        if index is None:
            raise CollectorError("unexpected nvidia-smi line: %r" % line)
        utilisation = _number(fields[1])
        cards.append({
            "index": int(index),
            "utilisation": None if utilisation is None else round(utilisation / 100.0, 4),
            "memory_used_mib": _rounded(_number(fields[2])),
            "memory_total_mib": _rounded(_number(fields[3])),
            "temperature_c": _rounded(_number(fields[4])),
            "power_w": _rounded(_number(fields[5])),
        })
    cards.sort(key=lambda card: card["index"])
    return cards


def run_nvidia_smi(executable="nvidia-smi", timeout=10.0):
    command = [executable, "--query-gpu=" + QUERY, "--format=csv,noheader,nounits"]
    try:
        proc = subprocess.Popen(command, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, universal_newlines=True)
    except OSError as exc:
        raise CollectorError("cannot run %s: %s" % (executable, exc))
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        raise CollectorError("%s timed out after %g s" % (executable, timeout))
    if proc.returncode != 0:
        detail = (err or out).strip().splitlines()
        raise CollectorError("%s exited with %d: %s"
                             % (executable, proc.returncode,
                                detail[0] if detail else "no output"))
    return out


class Collector(object):
    """Caches the result (or the failure) of the last nvidia-smi run."""

    def __init__(self, node, interval=5.0, run=run_nvidia_smi, clock=time.monotonic):
        self.node = node
        self.interval = interval
        self._run = run
        self._clock = clock
        self._lock = threading.Lock()
        self._at = None
        self._result = None

    def snapshot(self):
        """Return (HTTP status, body dict)."""
        with self._lock:
            now = self._clock()
            if self._at is None or now - self._at >= self.interval:
                try:
                    cards = parse_nvidia_smi(self._run())
                    self._result = (200, {"node": self.node, "cards": cards})
                except CollectorError as exc:
                    self._result = (503, {"error": "nvidia_smi_unavailable",
                                          "detail": str(exc)})
                self._at = now
            return self._result


class ThreadingServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def make_handler(collector):
    class Handler(BaseHTTPRequestHandler):
        server_version = "gpu-collector/1"

        def do_GET(self):
            if self.path.split("?")[0] == "/metrics.json":
                status, body = collector.snapshot()
            else:
                status, body = 404, {"error": "not_found"}
            payload = json.dumps(body).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, format, *args):
            pass  # one request per node per poll; keep the journal quiet

    return Handler


def make_server(bind, port, collector):
    return ThreadingServer((bind, port), make_handler(collector))


def short_hostname():
    return socket.gethostname().split(".")[0]


def main(argv=None):
    parser = argparse.ArgumentParser(description="Serve nvidia-smi metrics as JSON.")
    parser.add_argument("--port", type=int, default=9455)
    parser.add_argument("--bind", default="0.0.0.0", help="address to listen on")
    parser.add_argument("--interval", type=float, default=5.0,
                        help="minimum seconds between nvidia-smi runs (default 5)")
    parser.add_argument("--nvidia-smi", default="nvidia-smi", help="path of the executable")
    parser.add_argument("--timeout", type=float, default=10.0,
                        help="seconds before an nvidia-smi run is abandoned")
    parser.add_argument("--node", default=None,
                        help="node name to report (default: short hostname)")
    args = parser.parse_args(argv)

    collector = Collector(
        args.node or short_hostname(), args.interval,
        run=lambda: run_nvidia_smi(args.nvidia_smi, args.timeout))
    server = make_server(args.bind, args.port, collector)
    sys.stderr.write("gpu collector for %s listening on %s:%d\n"
                     % (collector.node, args.bind, args.port))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
