"""Partition utilization snapshots."""

from __future__ import annotations

from prometheus_client import CollectorRegistry, Gauge

from slurm_monitor.client import SlurmrestdClient
from slurm_monitor.collectors._helpers import as_int, as_str_list, first_present, safe_iter
from slurm_monitor.collectors.base import Collector
from slurm_monitor.collectors.self_metrics import SelfMetrics

PART_LABELS = ("cluster", "partition")
PART_STATE_LABELS = ("cluster", "partition", "state")


class PartitionsCollector(Collector):
    name = "partitions"

    def __init__(
        self,
        client: SlurmrestdClient,
        self_metrics: SelfMetrics,
        registry: CollectorRegistry,
        cluster: str,
    ) -> None:
        super().__init__(client, self_metrics)
        self._cluster = cluster

        self.cpus_total = Gauge(
            "slurm_partition_cpus_total",
            "Total CPUs in the partition.",
            PART_LABELS,
            registry=registry,
        )
        self.nodes_total = Gauge(
            "slurm_partition_nodes_total",
            "Total nodes in the partition.",
            PART_LABELS,
            registry=registry,
        )
        self.max_time_minutes = Gauge(
            "slurm_partition_max_time_minutes",
            "Configured MaxTime for the partition (minutes).",
            PART_LABELS,
            registry=registry,
        )
        self.default_time_minutes = Gauge(
            "slurm_partition_default_time_minutes",
            "Configured DefaultTime for the partition (minutes).",
            PART_LABELS,
            registry=registry,
        )
        self.state = Gauge(
            "slurm_partition_state",
            "Partition state as a 1-hot gauge.",
            PART_STATE_LABELS,
            registry=registry,
        )

    async def collect(self) -> None:
        payload = await self._client.get("partitions")
        parts = safe_iter(payload.get("partitions"))

        for g in (
            self.cpus_total,
            self.nodes_total,
            self.max_time_minutes,
            self.default_time_minutes,
            self.state,
        ):
            g._metrics.clear()  # type: ignore[attr-defined]

        for p in parts:
            name = str(first_present(p, "name", default="unknown"))
            cpus = as_int(first_present(p, "total_cpus", "cpus"))
            nodes = as_int(first_present(p, "total_nodes", "node_count", "nodes"))
            max_time = as_int(first_present(p, "maximum_time", "max_time"))
            default_time = as_int(first_present(p, "default_time"))
            states = as_str_list(first_present(p, "state", "states"))

            self.cpus_total.labels(self._cluster, name).set(cpus)
            self.nodes_total.labels(self._cluster, name).set(nodes)
            if max_time > 0:
                self.max_time_minutes.labels(self._cluster, name).set(max_time)
            if default_time > 0:
                self.default_time_minutes.labels(self._cluster, name).set(default_time)
            for state in states or ["UNKNOWN"]:
                self.state.labels(self._cluster, name, state).set(1)
