"""GPU metrics sources: Prometheus (DCGM exporter) and the per-node collector."""

from __future__ import annotations

import httpx
import pytest

from slurm_monitor_server.config import GpuMetricsSettings
from slurm_monitor_server.gpu_metrics import (
    CollectorGpuMetrics,
    GpuMetricsError,
    NoGpuMetrics,
    PrometheusGpuMetrics,
    build_gpu_metrics_source,
)
from slurm_monitor_server.records import CardMetrics

DCGM = {
    "DCGM_FI_DEV_GPU_UTIL": 97,
    "DCGM_FI_DEV_FB_USED": 36864,
    "DCGM_FI_DEV_FB_FREE": 4096,
    "DCGM_FI_DEV_GPU_TEMP": 74,
    "DCGM_FI_DEV_POWER_USAGE": 286.4,
}


def prometheus_handler(node_label: str, node_value: str, queries: list[str]):
    def handle(request: httpx.Request) -> httpx.Response:
        query = request.url.params["query"]
        queries.append(query)
        name = query.split("{")[0]
        result = [
            {"metric": {"__name__": name, node_label: node_value, "gpu": "0"},
             "value": [1790000000, str(DCGM[name])]},
            {"metric": {"__name__": name, node_label: "not-a-gpu-node", "gpu": "0"},
             "value": [1790000000, "1"]},
            {"metric": {"__name__": name, node_label: node_value, "gpu": "x"},
             "value": [1790000000, "1"]},
        ]  # fmt: skip
        return httpx.Response(
            200, json={"status": "success", "data": {"resultType": "vector", "result": result}}
        )

    return handle


@pytest.mark.parametrize(
    ("label", "value"),
    [("Hostname", "gpu-005"), ("instance", "gpu-005.example.org:9400"), ("node", "gpu-005:9400")],
)
async def test_prometheus_source(label, value):
    queries: list[str] = []
    settings = GpuMetricsSettings(
        source="prometheus",
        prometheus_url="https://prometheus.example.org",
        prometheus_node_label=label,
        prometheus_extra_matchers='cluster="example"',
    )
    source = PrometheusGpuMetrics(
        settings, httpx.MockTransport(prometheus_handler(label, value, queries))
    )
    metrics = await source.read(["gpu-005", "gpu-006"])
    await source.close()
    assert metrics == {("gpu-005", 0): CardMetrics(0.97, 36864, 40960, 74, 286)}
    assert sorted(queries) == sorted(f'{name}{{cluster="example"}}' for name in DCGM)


async def test_prometheus_failure_raises():
    settings = GpuMetricsSettings(
        source="prometheus", prometheus_url="https://prometheus.example.org"
    )
    source = PrometheusGpuMetrics(settings, httpx.MockTransport(lambda r: httpx.Response(502)))
    with pytest.raises(GpuMetricsError):
        await source.read(["gpu-005"])
    await source.close()


async def test_collector_source_tolerates_single_nodes_failing():
    def handle(request: httpx.Request) -> httpx.Response:
        assert request.url.port == 9455 and request.url.path == "/metrics.json"
        if request.url.host == "gpu-006":
            raise httpx.ConnectError("node is down")
        return httpx.Response(200, json={
            "node": "gpu-005",
            "cards": [
                {"index": 0, "utilisation": 0.97, "memory_used_mib": 36864,
                 "memory_total_mib": 40960, "temperature_c": 74, "power_w": 286},
                {"index": 1, "utilisation": None, "memory_used_mib": 3,
                 "memory_total_mib": 40960, "temperature_c": 31.6, "power_w": 55.2},
                {"utilisation": 0.5},
            ],
        })  # fmt: skip

    source = CollectorGpuMetrics(
        GpuMetricsSettings(source="collector"), httpx.MockTransport(handle)
    )
    metrics = await source.read(["gpu-005", "gpu-006"])
    assert metrics == {
        ("gpu-005", 0): CardMetrics(0.97, 36864, 40960, 74, 286),
        ("gpu-005", 1): CardMetrics(None, 3, 40960, 32, 55),
    }
    assert await source.read([]) == {}
    with pytest.raises(GpuMetricsError):
        await source.read(["gpu-006"])
    await source.close()


async def test_source_selection():
    assert isinstance(build_gpu_metrics_source(GpuMetricsSettings()), NoGpuMetrics)
    assert not NoGpuMetrics.provides_metrics
    assert await NoGpuMetrics().read(["gpu-005"]) == {}
    collector = build_gpu_metrics_source(GpuMetricsSettings(source="collector"))
    assert isinstance(collector, CollectorGpuMetrics)
    await collector.close()
    with pytest.raises(ValueError, match="prometheus_url"):
        GpuMetricsSettings(source="prometheus")
