"""Scheduler diagnostics — cycle times, backfill stats, RPC counters."""

from __future__ import annotations

from prometheus_client import CollectorRegistry, Counter, Gauge

from slurm_monitor.client import SlurmrestdClient
from slurm_monitor.collectors._helpers import as_int, first_present
from slurm_monitor.collectors.base import Collector
from slurm_monitor.collectors.self_metrics import SelfMetrics

DIAG_LABELS = ("cluster",)


class DiagnosticsCollector(Collector):
    name = "diag"

    def __init__(
        self,
        client: SlurmrestdClient,
        self_metrics: SelfMetrics,
        registry: CollectorRegistry,
        cluster: str,
    ) -> None:
        super().__init__(client, self_metrics)
        self._cluster = cluster

        self.schedule_cycle_last_us = Gauge(
            "slurm_scheduler_cycle_last_microseconds",
            "Duration of the most recent main scheduler cycle (microseconds).",
            DIAG_LABELS,
            registry=registry,
        )
        self.schedule_cycle_max_us = Gauge(
            "slurm_scheduler_cycle_max_microseconds",
            "Longest main scheduler cycle observed since slurmctld started (microseconds).",
            DIAG_LABELS,
            registry=registry,
        )
        self.schedule_queue_length = Gauge(
            "slurm_scheduler_queue_length",
            "Pending RPC queue length seen by the main scheduler.",
            DIAG_LABELS,
            registry=registry,
        )
        self.bf_cycle_last_us = Gauge(
            "slurm_backfill_cycle_last_microseconds",
            "Duration of the most recent backfill cycle (microseconds).",
            DIAG_LABELS,
            registry=registry,
        )
        self.bf_last_depth = Gauge(
            "slurm_backfill_last_depth",
            "Number of jobs evaluated in the most recent backfill cycle.",
            DIAG_LABELS,
            registry=registry,
        )
        self.jobs_started = Counter(
            "slurm_jobs_started_total",
            "Cumulative number of jobs started since slurmctld started.",
            DIAG_LABELS,
            registry=registry,
        )
        self.jobs_completed = Counter(
            "slurm_jobs_completed_total",
            "Cumulative number of jobs that completed since slurmctld started.",
            DIAG_LABELS,
            registry=registry,
        )
        self._last_started: int | None = None
        self._last_completed: int | None = None

    async def collect(self) -> None:
        payload = await self._client.get("diag")
        stats = first_present(payload, "statistics", default=payload) or {}
        if not isinstance(stats, dict):
            return

        self.schedule_cycle_last_us.labels(self._cluster).set(
            as_int(first_present(stats, "schedule_cycle_last", "main_cycle_last"))
        )
        self.schedule_cycle_max_us.labels(self._cluster).set(
            as_int(first_present(stats, "schedule_cycle_max", "main_cycle_max"))
        )
        self.schedule_queue_length.labels(self._cluster).set(
            as_int(first_present(stats, "schedule_queue_length"))
        )
        self.bf_cycle_last_us.labels(self._cluster).set(
            as_int(first_present(stats, "bf_cycle_last", "backfill_cycle_last"))
        )
        self.bf_last_depth.labels(self._cluster).set(
            as_int(first_present(stats, "bf_last_depth", "backfill_last_depth"))
        )

        # Diagnostics returns a counter, not a delta. Convert to monotonic
        # counter increments while tolerating slurmctld restarts (which reset).
        started = as_int(first_present(stats, "jobs_started"))
        completed = as_int(first_present(stats, "jobs_completed"))
        if self._last_started is not None and started >= self._last_started:
            self.jobs_started.labels(self._cluster).inc(started - self._last_started)
        elif self._last_started is not None and started < self._last_started:
            # ctld restart; bump by current value since previous baseline is gone.
            self.jobs_started.labels(self._cluster).inc(started)
        self._last_started = started

        if self._last_completed is not None and completed >= self._last_completed:
            self.jobs_completed.labels(self._cluster).inc(completed - self._last_completed)
        elif self._last_completed is not None and completed < self._last_completed:
            self.jobs_completed.labels(self._cluster).inc(completed)
        self._last_completed = completed
