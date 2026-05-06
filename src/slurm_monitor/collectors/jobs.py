"""Job-state aggregation metrics.

Important cardinality rule: we never emit per-jobid series. We aggregate by
(cluster, partition, qos, account, user, state) and (for pending jobs) by
``reason``. ``user`` is allowed per the Albedo deployment decision.
"""

from __future__ import annotations

import time
from collections import defaultdict

from prometheus_client import CollectorRegistry, Gauge

from slurm_monitor.client import SlurmrestdClient
from slurm_monitor.collectors._helpers import as_int, as_str_list, first_present, safe_iter
from slurm_monitor.collectors.base import Collector
from slurm_monitor.collectors.self_metrics import SelfMetrics

JOB_LABELS = ("cluster", "partition", "qos", "account", "user", "state")
PENDING_LABELS = ("cluster", "partition", "qos", "account", "user", "reason")
WAIT_LABELS = ("cluster", "partition", "qos")


class JobsCollector(Collector):
    name = "jobs"

    def __init__(
        self,
        client: SlurmrestdClient,
        self_metrics: SelfMetrics,
        registry: CollectorRegistry,
        cluster: str,
    ) -> None:
        super().__init__(client, self_metrics)
        self._cluster = cluster

        self.jobs = Gauge(
            "slurm_jobs",
            "Number of jobs aggregated by partition/qos/account/user/state.",
            JOB_LABELS,
            registry=registry,
        )
        self.cpus = Gauge(
            "slurm_jobs_cpus",
            "CPU count summed across jobs in the same group.",
            JOB_LABELS,
            registry=registry,
        )
        self.gpus = Gauge(
            "slurm_jobs_gpus",
            "GPU count summed across jobs in the same group (parsed from tres).",
            JOB_LABELS,
            registry=registry,
        )
        self.nodes = Gauge(
            "slurm_jobs_nodes",
            "Node count summed across jobs in the same group.",
            JOB_LABELS,
            registry=registry,
        )
        self.pending_by_reason = Gauge(
            "slurm_jobs_pending_by_reason",
            "Pending jobs broken down by Slurm 'reason'.",
            PENDING_LABELS,
            registry=registry,
        )
        self.wait_seconds_max = Gauge(
            "slurm_jobs_wait_seconds_max",
            "Longest current wait time among pending jobs in this group.",
            WAIT_LABELS,
            registry=registry,
        )
        self.wait_seconds_sum = Gauge(
            "slurm_jobs_wait_seconds_sum",
            "Sum of current wait times across pending jobs in this group.",
            WAIT_LABELS,
            registry=registry,
        )

    async def collect(self) -> None:
        # ``flags=show_all`` returns running + pending; sacct/dbd is not required.
        payload = await self._client.get("jobs", params={"flags": "show_all"})
        jobs = safe_iter(payload.get("jobs"))
        now = time.time()

        # Reset label-keyed gauges; gauge label sets are recomputed each pass.
        for g in (
            self.jobs,
            self.cpus,
            self.gpus,
            self.nodes,
            self.pending_by_reason,
            self.wait_seconds_max,
            self.wait_seconds_sum,
        ):
            g._metrics.clear()  # type: ignore[attr-defined]

        agg_count: dict[tuple, int] = defaultdict(int)
        agg_cpus: dict[tuple, int] = defaultdict(int)
        agg_gpus: dict[tuple, int] = defaultdict(int)
        agg_nodes: dict[tuple, int] = defaultdict(int)
        pending_by_reason: dict[tuple, int] = defaultdict(int)
        wait_max: dict[tuple, float] = defaultdict(float)
        wait_sum: dict[tuple, float] = defaultdict(float)

        for j in jobs:
            partition = str(first_present(j, "partition", default="unknown"))
            qos = str(first_present(j, "qos", default="unknown"))
            account = str(first_present(j, "account", default="unknown"))
            user = str(first_present(j, "user_name", "user", default="unknown"))
            states = as_str_list(first_present(j, "job_state"))
            state = states[0] if states else "UNKNOWN"

            cpus = as_int(first_present(j, "cpus", "num_cpus"))
            n_nodes = as_int(first_present(j, "node_count", "num_nodes"))
            gpus = _gpu_count_from_tres(first_present(j, "tres_alloc_str", "tres_per_node"))

            k = (self._cluster, partition, qos, account, user, state)
            agg_count[k] += 1
            agg_cpus[k] += cpus
            agg_gpus[k] += gpus
            agg_nodes[k] += n_nodes

            if state == "PENDING":
                reason = str(first_present(j, "state_reason", "reason", default="None"))
                pk = (self._cluster, partition, qos, account, user, reason)
                pending_by_reason[pk] += 1

                submit = as_int(first_present(j, "submit_time"))
                if submit > 0:
                    wait = max(0.0, now - submit)
                    wk = (self._cluster, partition, qos)
                    if wait > wait_max[wk]:
                        wait_max[wk] = wait
                    wait_sum[wk] += wait

        for k, v in agg_count.items():
            self.jobs.labels(*k).set(v)
        for k, v in agg_cpus.items():
            self.cpus.labels(*k).set(v)
        for k, v in agg_gpus.items():
            self.gpus.labels(*k).set(v)
        for k, v in agg_nodes.items():
            self.nodes.labels(*k).set(v)
        for k, v in pending_by_reason.items():
            self.pending_by_reason.labels(*k).set(v)
        for k, v in wait_max.items():
            self.wait_seconds_max.labels(*k).set(v)
        for k, v in wait_sum.items():
            self.wait_seconds_sum.labels(*k).set(v)


def _gpu_count_from_tres(tres: str | None) -> int:
    """Extract GPU count from a TRES string like 'cpu=4,mem=16G,gres/gpu=2'."""

    if not tres:
        return 0
    total = 0
    for token in str(tres).split(","):
        token = token.strip()
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        key = key.strip().lower()
        if key.startswith("gres/gpu") or key == "gpu":
            try:
                total += int(value.strip())
            except ValueError:
                continue
    return total
