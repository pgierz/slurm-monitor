"""Compact internal records.

A poll reduces slurmrestd's large payloads to these at once; everything the
server later computes is derived from them.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class JobRecord:
    job_id: int
    name: str
    user: str
    account: str
    partition: str  # may be a comma-separated list for pending jobs
    qos: str
    state: str  # "R" or "PD"; jobs in other states are not kept
    reason: str  # raw Slurm state reason
    submit_time: int | None
    start_time: int | None  # start (running) or expected start (pending)
    time_limit_seconds: int | None  # None for unlimited or unknown
    node_count: int
    cpus: int
    gpu_count: int
    gpu_type: str  # lower-case GRES type, empty when untyped or no GPUs
    gpu_cards: tuple[tuple[str, int], ...]  # (node name, card index) when derivable
    runner_kind: str | None  # "ci", "dask", "jupyterhub", "extra:<key>" or None
    is_dask_scheduler: bool
    dask_cluster: str  # value of the grouping field, empty when absent

    def in_partition(self, partition: str) -> bool:
        return partition in self.partition.split(",")


@dataclass(frozen=True, slots=True)
class NodeRecord:
    name: str
    state: str  # contract state: allocated, idle, drained, down
    partitions: tuple[str, ...]
    gpu_types: tuple[str, ...]  # one entry per card, by card index
    gpu_allocated: frozenset[int]  # allocated card indices


@dataclass(frozen=True, slots=True)
class QosRecord:
    name: str
    cpu_limit: int | None
    max_wall_seconds: int | None


@dataclass(frozen=True, slots=True)
class ShareRecord:
    user: str
    account: str
    fairshare: float | None


@dataclass(frozen=True, slots=True)
class CardMetrics:
    utilisation: float | None = None  # 0…1
    memory_used_mib: int | None = None
    memory_total_mib: int | None = None
    temperature_c: int | None = None
    power_w: int | None = None


GpuMetrics = dict[tuple[str, int], CardMetrics]


@dataclass(frozen=True, slots=True)
class ClusterState:
    """Everything one successful poll yields."""

    polled_at: int  # Unix seconds
    jobs: tuple[JobRecord, ...]
    nodes: tuple[NodeRecord, ...]
    qos: tuple[QosRecord, ...]
    shares: tuple[ShareRecord, ...]
    metrics_available: bool = False
    gpu_metrics: GpuMetrics = field(default_factory=dict)
