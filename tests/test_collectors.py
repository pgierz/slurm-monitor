"""Collector-level tests with a fake slurmrestd client.

Avoids the network entirely — we wire each collector to a stub client that
returns a canned payload, run ``collect()``, and assert on the metric output.
"""

from __future__ import annotations

from typing import Any

import pytest
from prometheus_client import CollectorRegistry, generate_latest

from slurm_monitor.collectors import (
    JobsCollector,
    NodesCollector,
    PartitionsCollector,
)
from slurm_monitor.collectors.self_metrics import SelfMetrics


class StubClient:
    def __init__(self, responses: dict[str, dict[str, Any]]) -> None:
        self._responses = responses

    @property
    def api_version(self) -> str:
        return "v0.0.39"

    async def detect_api_version(self) -> str:
        return "v0.0.39"

    async def get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        if path not in self._responses:
            raise KeyError(path)
        return self._responses[path]

    async def aclose(self) -> None:
        pass


def _exposition(registry: CollectorRegistry) -> str:
    return generate_latest(registry).decode()


@pytest.mark.asyncio
async def test_nodes_collector_aggregates_states_and_gpus():
    registry = CollectorRegistry()
    self_metrics = SelfMetrics(registry, cluster="albedo")
    payload = {
        "nodes": [
            {
                "name": "albedo001",
                "partitions": ["compute"],
                "state": ["IDLE"],
                "cpus": 128,
                "alloc_cpus": 0,
                "real_memory": 256000,
                "alloc_memory": 0,
                "free_memory": 250000,
                "cpu_load": 25,
                "gres": "",
                "gres_used": "",
            },
            {
                "name": "albedo-gpu1",
                "partitions": ["gpu"],
                "state": ["MIXED"],
                "cpus": 64,
                "alloc_cpus": 32,
                "real_memory": 512000,
                "alloc_memory": 256000,
                "free_memory": 250000,
                "cpu_load": 1500,
                "gres": "gpu:a100:4",
                "gres_used": "gpu:a100:2",
            },
            {
                "name": "albedo-gpu2",
                "partitions": ["gpu"],
                "state": ["IDLE", "PLANNED"],
                "cpus": 32,
                "alloc_cpus": 0,
                "real_memory": 256000,
                "alloc_memory": 0,
                "free_memory": 250000,
                "cpu_load": 0,
                "gres": "gpu:a40:1",
                "gres_used": "",
            },
        ]
    }
    client = StubClient({"nodes": payload})
    nc = NodesCollector(client, self_metrics, registry, cluster="albedo")  # type: ignore[arg-type]
    await nc.collect()

    text = _exposition(registry)
    assert 'slurm_node_cpus_total{cluster="albedo",gpu_type="none",node="albedo001",partition="compute"} 128.0' in text
    assert 'slurm_node_gpus_total{cluster="albedo",gpu_type="a100",node="albedo-gpu1",partition="gpu"} 4.0' in text
    assert 'slurm_node_gpus_alloc{cluster="albedo",gpu_type="a100",node="albedo-gpu1",partition="gpu"} 2.0' in text
    assert 'slurm_partition_gpus_total{cluster="albedo",gpu_type="a100",partition="gpu"} 4.0' in text
    assert 'slurm_partition_gpus_total{cluster="albedo",gpu_type="a40",partition="gpu"} 1.0' in text
    # State counters: IDLE on compute=1, MIXED on gpu=1, IDLE+PLANNED on gpu=1+1.
    assert 'slurm_nodes_state_count{cluster="albedo",partition="compute",state="IDLE"} 1.0' in text
    assert 'slurm_nodes_state_count{cluster="albedo",partition="gpu",state="IDLE"} 1.0' in text
    assert 'slurm_nodes_state_count{cluster="albedo",partition="gpu",state="MIXED"} 1.0' in text
    assert 'slurm_nodes_state_count{cluster="albedo",partition="gpu",state="PLANNED"} 1.0' in text


@pytest.mark.asyncio
async def test_jobs_collector_aggregates_pending_and_running():
    registry = CollectorRegistry()
    self_metrics = SelfMetrics(registry, cluster="albedo")
    payload = {
        "jobs": [
            {
                "job_state": "RUNNING",
                "partition": "compute",
                "qos": "normal",
                "account": "awi",
                "user_name": "alice",
                "cpus": 32,
                "node_count": 1,
                "tres_alloc_str": "cpu=32,mem=64G",
            },
            {
                "job_state": "RUNNING",
                "partition": "gpu",
                "qos": "normal",
                "account": "awi",
                "user_name": "bob",
                "cpus": 8,
                "node_count": 1,
                "tres_alloc_str": "cpu=8,mem=32G,gres/gpu=2",
            },
            {
                "job_state": "PENDING",
                "partition": "gpu",
                "qos": "normal",
                "account": "awi",
                "user_name": "alice",
                "cpus": 16,
                "node_count": 1,
                "tres_alloc_str": "cpu=16,mem=64G,gres/gpu=4",
                "state_reason": "Resources",
                "submit_time": 1,
            },
        ]
    }
    client = StubClient({"jobs": payload})
    jc = JobsCollector(client, self_metrics, registry, cluster="albedo")  # type: ignore[arg-type]
    await jc.collect()

    text = _exposition(registry)
    assert 'slurm_jobs{account="awi",cluster="albedo",partition="compute",qos="normal",state="RUNNING",user="alice"} 1.0' in text
    assert 'slurm_jobs{account="awi",cluster="albedo",partition="gpu",qos="normal",state="RUNNING",user="bob"} 1.0' in text
    assert 'slurm_jobs_gpus{account="awi",cluster="albedo",partition="gpu",qos="normal",state="RUNNING",user="bob"} 2.0' in text
    assert 'slurm_jobs_pending_by_reason{account="awi",cluster="albedo",partition="gpu",qos="normal",reason="Resources",user="alice"} 1.0' in text


@pytest.mark.asyncio
async def test_partitions_collector_emits_state_one_hot():
    registry = CollectorRegistry()
    self_metrics = SelfMetrics(registry, cluster="albedo")
    payload = {
        "partitions": [
            {
                "name": "compute",
                "total_cpus": 4096,
                "total_nodes": 200,
                "state": "UP",
                "maximum_time": 2880,
                "default_time": 60,
            },
            {
                "name": "gpu",
                "total_cpus": 1024,
                "total_nodes": 40,
                "state": ["UP"],
                "maximum_time": 1440,
            },
        ]
    }
    client = StubClient({"partitions": payload})
    pc = PartitionsCollector(client, self_metrics, registry, cluster="albedo")  # type: ignore[arg-type]
    await pc.collect()

    text = _exposition(registry)
    assert 'slurm_partition_cpus_total{cluster="albedo",partition="compute"} 4096.0' in text
    assert 'slurm_partition_state{cluster="albedo",partition="compute",state="UP"} 1.0' in text
    assert 'slurm_partition_max_time_minutes{cluster="albedo",partition="gpu"} 1440.0' in text
