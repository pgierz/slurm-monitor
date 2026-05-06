"""Exporter health metrics — how the exporter itself is doing."""

from __future__ import annotations

from prometheus_client import CollectorRegistry, Counter, Gauge, Info


class SelfMetrics:
    """Wraps the exporter's own metrics (scrape duration, errors, info)."""

    def __init__(self, registry: CollectorRegistry, cluster: str) -> None:
        self._cluster = cluster
        self.up = Gauge(
            "slurm_monitor_up",
            "1 if the exporter has successfully populated metrics for this collector at least once.",
            ["cluster", "collector"],
            registry=registry,
        )
        self.last_success = Gauge(
            "slurm_monitor_collector_last_success_timestamp_seconds",
            "Unix timestamp of the most recent successful collection.",
            ["cluster", "collector"],
            registry=registry,
        )
        self.duration = Gauge(
            "slurm_monitor_collector_duration_seconds",
            "Duration of the most recent successful collection.",
            ["cluster", "collector"],
            registry=registry,
        )
        self.errors = Counter(
            "slurm_monitor_collector_errors_total",
            "Number of failed collection attempts.",
            ["cluster", "collector", "reason"],
            registry=registry,
        )
        self.info = Info(
            "slurm_monitor_build",
            "Build / runtime info for the exporter.",
            registry=registry,
        )
        self.api_version = Gauge(
            "slurm_monitor_slurm_api_version_info",
            "Active slurmrestd OpenAPI version, exposed as a label only.",
            ["cluster", "version"],
            registry=registry,
        )

    def record_success(self, collector: str, duration_s: float) -> None:
        import time as _t

        self.up.labels(self._cluster, collector).set(1)
        self.last_success.labels(self._cluster, collector).set(_t.time())
        self.duration.labels(self._cluster, collector).set(duration_s)

    def record_error(self, collector: str, reason: str) -> None:
        # Don't flip up=0 for transient errors — let staleness alerts handle that.
        self.errors.labels(self._cluster, collector, reason).inc()

    def set_api_version(self, version: str) -> None:
        # Reset previous gauges by clearing then setting; prometheus_client lacks a clear here.
        self.api_version.labels(self._cluster, version).set(1)
