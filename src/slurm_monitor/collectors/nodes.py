"""Per-node and aggregated node-state metrics."""

from __future__ import annotations

import re
from collections import defaultdict

from prometheus_client import CollectorRegistry, Gauge

from slurm_monitor.client import SlurmrestdClient
from slurm_monitor.collectors._helpers import as_float, as_int, as_str_list, first_present, safe_iter
from slurm_monitor.collectors.base import Collector
from slurm_monitor.collectors.self_metrics import SelfMetrics

# Cardinality budget for Albedo: ~240 nodes × small label set.
NODE_LABELS = ("cluster", "node", "partition", "gpu_type")
STATE_LABELS = ("cluster", "partition", "state")
GPU_LABELS = ("cluster", "partition", "gpu_type")

_GRES_GPU_RE = re.compile(r"gpu(?::([^:]+))?:(\d+)")


def _gpu_breakdown(gres: str) -> dict[str, int]:
    """Parse a GRES string like ``gpu:a100:4`` or ``gpu:4`` -> {model: count}."""

    out: dict[str, int] = defaultdict(int)
    if not gres:
        return out
    for m in _GRES_GPU_RE.finditer(gres):
        model = (m.group(1) or "unknown").lower()
        try:
            out[model] += int(m.group(2))
        except ValueError:
            continue
    return out


class NodesCollector(Collector):
    name = "nodes"

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
            "slurm_node_cpus_total",
            "Total CPUs configured on the node.",
            NODE_LABELS,
            registry=registry,
        )
        self.cpus_alloc = Gauge(
            "slurm_node_cpus_alloc",
            "Allocated CPUs on the node.",
            NODE_LABELS,
            registry=registry,
        )
        self.cpu_load = Gauge(
            "slurm_node_cpu_load",
            "Reported one-minute CPU load (cpu_load / 100).",
            NODE_LABELS,
            registry=registry,
        )
        self.real_memory_mb = Gauge(
            "slurm_node_real_memory_mb",
            "Real (configured) memory in MB.",
            NODE_LABELS,
            registry=registry,
        )
        self.alloc_memory_mb = Gauge(
            "slurm_node_alloc_memory_mb",
            "Allocated memory in MB.",
            NODE_LABELS,
            registry=registry,
        )
        self.free_memory_mb = Gauge(
            "slurm_node_free_memory_mb",
            "Free memory reported by the node in MB.",
            NODE_LABELS,
            registry=registry,
        )
        self.gpus_total = Gauge(
            "slurm_node_gpus_total",
            "Total GPUs configured on the node, by GPU model.",
            NODE_LABELS,
            registry=registry,
        )
        self.gpus_alloc = Gauge(
            "slurm_node_gpus_alloc",
            "Allocated GPUs on the node, by GPU model.",
            NODE_LABELS,
            registry=registry,
        )
        self.state = Gauge(
            "slurm_node_state",
            "Node state as a 1-hot gauge, one series per state token.",
            (*NODE_LABELS, "state"),
            registry=registry,
        )

        self.state_count = Gauge(
            "slurm_nodes_state_count",
            "Number of nodes in a given state, per partition.",
            STATE_LABELS,
            registry=registry,
        )
        self.gpus_total_partition = Gauge(
            "slurm_partition_gpus_total",
            "Total GPUs configured per partition / GPU model.",
            GPU_LABELS,
            registry=registry,
        )
        self.gpus_alloc_partition = Gauge(
            "slurm_partition_gpus_alloc",
            "Allocated GPUs per partition / GPU model.",
            GPU_LABELS,
            registry=registry,
        )

    async def collect(self) -> None:
        payload = await self._client.get("nodes")
        nodes = safe_iter(payload.get("nodes"))

        # Reset gauges that depend on label-set composition (e.g. partitions
        # may move between scrapes). Counters are not affected.
        self.state_count._metrics.clear()  # type: ignore[attr-defined]
        self.gpus_total_partition._metrics.clear()  # type: ignore[attr-defined]
        self.gpus_alloc_partition._metrics.clear()  # type: ignore[attr-defined]
        self.state._metrics.clear()  # type: ignore[attr-defined]

        per_part_state: dict[tuple[str, str], int] = defaultdict(int)
        per_part_gpu_total: dict[tuple[str, str], int] = defaultdict(int)
        per_part_gpu_alloc: dict[tuple[str, str], int] = defaultdict(int)

        for n in nodes:
            name = str(first_present(n, "name", "hostname", default="unknown"))
            partitions = first_present(n, "partitions", default=[]) or []
            if not isinstance(partitions, list) or not partitions:
                partitions = ["__none__"]
            states = as_str_list(first_present(n, "state", "states"))

            cpus_total = as_int(first_present(n, "cpus", "configured_cpus"))
            cpus_alloc = as_int(first_present(n, "alloc_cpus", "allocated_cpus"))
            cpu_load = as_float(first_present(n, "cpu_load")) / 100.0
            real_mem = as_int(first_present(n, "real_memory", "configured_memory"))
            alloc_mem = as_int(first_present(n, "alloc_memory", "allocated_memory"))
            free_mem = as_int(first_present(n, "free_memory"))

            gres_total = str(first_present(n, "gres", default=""))
            gres_used = str(first_present(n, "gres_used", default=""))
            gpu_total = _gpu_breakdown(gres_total)
            gpu_used = _gpu_breakdown(gres_used)

            # The "primary" GPU model on this node (used as a series label).
            gpu_models = set(gpu_total) | set(gpu_used)
            gpu_label = "+".join(sorted(gpu_models)) if gpu_models else "none"

            for part in partitions:
                labels = (self._cluster, name, str(part), gpu_label)
                self.cpus_total.labels(*labels).set(cpus_total)
                self.cpus_alloc.labels(*labels).set(cpus_alloc)
                self.cpu_load.labels(*labels).set(cpu_load)
                self.real_memory_mb.labels(*labels).set(real_mem)
                self.alloc_memory_mb.labels(*labels).set(alloc_mem)
                self.free_memory_mb.labels(*labels).set(free_mem)

                for model in gpu_models:
                    g_labels = (self._cluster, name, str(part), model)
                    self.gpus_total.labels(*g_labels).set(gpu_total.get(model, 0))
                    self.gpus_alloc.labels(*g_labels).set(gpu_used.get(model, 0))
                    per_part_gpu_total[(str(part), model)] += gpu_total.get(model, 0)
                    per_part_gpu_alloc[(str(part), model)] += gpu_used.get(model, 0)

                for state in states or ["UNKNOWN"]:
                    self.state.labels(*labels, state).set(1)
                    per_part_state[(str(part), state)] += 1

        for (part, state), count in per_part_state.items():
            self.state_count.labels(self._cluster, part, state).set(count)
        for (part, model), count in per_part_gpu_total.items():
            self.gpus_total_partition.labels(self._cluster, part, model).set(count)
        for (part, model), count in per_part_gpu_alloc.items():
            self.gpus_alloc_partition.labels(self._cluster, part, model).set(count)
