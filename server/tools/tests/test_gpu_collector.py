import json
import os
import stat
import threading
import urllib.error
import urllib.request

import pytest

import gpu_collector as gc

SAMPLE = "0, 97, 36864, 40960, 74, 286.43\n1, 0, 3, 40960, 31, 52.10\n"
SAMPLE_NA = "1, [N/A], 1024, 40960, [N/A], [N/A]\n0, 12, 512, 40960, 40, [Not Supported]\n"


def test_parse_matches_contract_example():
    cards = gc.parse_nvidia_smi(SAMPLE)
    assert cards[0] == {"index": 0, "utilisation": 0.97, "memory_used_mib": 36864,
                        "memory_total_mib": 40960, "temperature_c": 74, "power_w": 286}
    assert list(cards[0]) == ["index", "utilisation", "memory_used_mib",
                              "memory_total_mib", "temperature_c", "power_w"]
    assert cards[1]["utilisation"] == 0.0 and cards[1]["power_w"] == 52


def test_parse_not_available_becomes_null_and_cards_are_sorted():
    cards = gc.parse_nvidia_smi(SAMPLE_NA)
    assert [c["index"] for c in cards] == [0, 1]
    assert cards[1]["utilisation"] is None
    assert cards[1]["temperature_c"] is None and cards[1]["power_w"] is None
    assert cards[1]["memory_used_mib"] == 1024
    assert cards[0]["power_w"] is None and cards[0]["utilisation"] == 0.12


def test_parse_empty_and_malformed():
    assert gc.parse_nvidia_smi("\n") == []
    with pytest.raises(gc.CollectorError):
        gc.parse_nvidia_smi("NVIDIA-SMI has failed because it couldn't communicate\n")
    with pytest.raises(gc.CollectorError):
        gc.parse_nvidia_smi("x, 1, 2, 3, 4, 5\n")


class Clock(object):
    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now


def test_cache_limits_runs():
    calls, clock = [], Clock()

    def run():
        calls.append(1)
        return SAMPLE

    collector = gc.Collector("gpu-001", interval=5.0, run=run, clock=clock)
    assert collector.snapshot()[0] == 200
    clock.now += 4.9
    collector.snapshot()
    assert len(calls) == 1
    clock.now += 0.2
    status, body = collector.snapshot()
    assert len(calls) == 2 and body["node"] == "gpu-001" and len(body["cards"]) == 2


def test_failure_is_503_and_recovers():
    state, clock = {"fail": True}, Clock()

    def run():
        if state["fail"]:
            raise gc.CollectorError("cannot run nvidia-smi: not found")
        return SAMPLE

    collector = gc.Collector("gpu-001", interval=5.0, run=run, clock=clock)
    status, body = collector.snapshot()
    assert status == 503 and body["error"] == "nvidia_smi_unavailable"
    assert "not found" in body["detail"]
    state["fail"] = False
    clock.now += 6
    assert collector.snapshot()[0] == 200


def fake_executable(tmp_path, script):
    path = tmp_path / "nvidia-smi"
    path.write_text("#!/bin/sh\n" + script)
    os.chmod(str(path), os.stat(str(path)).st_mode | stat.S_IEXEC)
    return str(path)


def test_run_nvidia_smi_with_fake_executable(tmp_path):
    exe = fake_executable(tmp_path, 'echo "$@" > %s/args\nprintf "0, 50, 1, 2, 3, 4.4\\n"\n'
                          % tmp_path)
    assert gc.parse_nvidia_smi(gc.run_nvidia_smi(exe))[0]["utilisation"] == 0.5
    args = (tmp_path / "args").read_text().strip()
    assert args == ("--query-gpu=index,utilization.gpu,memory.used,memory.total,"
                    "temperature.gpu,power.draw --format=csv,noheader,nounits")


def test_run_nvidia_smi_missing_failing_and_hanging(tmp_path):
    with pytest.raises(gc.CollectorError) as info:
        gc.run_nvidia_smi(str(tmp_path / "absent"))
    assert "cannot run" in str(info.value)
    exe = fake_executable(tmp_path, "echo 'No devices were found' >&2\nexit 6\n")
    with pytest.raises(gc.CollectorError) as info:
        gc.run_nvidia_smi(exe)
    assert "exited with 6" in str(info.value) and "No devices" in str(info.value)
    exe = fake_executable(tmp_path, "exec sleep 5\n")
    with pytest.raises(gc.CollectorError) as info:
        gc.run_nvidia_smi(exe, timeout=0.2)
    assert "timed out" in str(info.value)


def fetch(port, path):
    try:
        response = urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, path), timeout=5)
    except urllib.error.HTTPError as exc:
        response = exc
    return response.getcode(), response.headers.get("Content-Type"), \
        json.loads(response.read().decode("utf-8"))


@pytest.fixture
def serve():
    servers = []

    def start(run):
        collector = gc.Collector("gpu-001", interval=5.0, run=run)
        server = gc.make_server("127.0.0.1", 0, collector)
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server.server_address[1]

    yield start
    for server in servers:
        server.shutdown()
        server.server_close()


def test_http_metrics(serve):
    port = serve(lambda: SAMPLE)
    status, content_type, body = fetch(port, "/metrics.json")
    assert status == 200 and content_type == "application/json"
    assert sorted(body) == ["cards", "node"] and body["node"] == "gpu-001"
    assert body["cards"][0]["utilisation"] == 0.97
    assert fetch(port, "/other")[0] == 404


def test_http_503_when_nvidia_smi_is_missing(serve, tmp_path):
    port = serve(lambda: gc.run_nvidia_smi(str(tmp_path / "absent")))
    status, content_type, body = fetch(port, "/metrics.json")
    assert status == 503 and content_type == "application/json"
    assert body["error"] == "nvidia_smi_unavailable"


def test_short_hostname_has_no_dots():
    assert "." not in gc.short_hostname()
