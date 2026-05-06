"""Reservations metrics."""

from __future__ import annotations

import time

from prometheus_client import CollectorRegistry, Gauge

from slurm_monitor.client import SlurmrestdClient
from slurm_monitor.collectors._helpers import as_int, first_present, safe_iter
from slurm_monitor.collectors.base import Collector
from slurm_monitor.collectors.self_metrics import SelfMetrics

RES_LABELS = ("cluster", "reservation", "partition", "users", "accounts")


class ReservationsCollector(Collector):
    name = "reservations"

    def __init__(
        self,
        client: SlurmrestdClient,
        self_metrics: SelfMetrics,
        registry: CollectorRegistry,
        cluster: str,
    ) -> None:
        super().__init__(client, self_metrics)
        self._cluster = cluster

        self.start_time = Gauge(
            "slurm_reservation_start_time_seconds",
            "Reservation start time (Unix seconds).",
            RES_LABELS,
            registry=registry,
        )
        self.end_time = Gauge(
            "slurm_reservation_end_time_seconds",
            "Reservation end time (Unix seconds).",
            RES_LABELS,
            registry=registry,
        )
        self.node_count = Gauge(
            "slurm_reservation_node_count",
            "Number of nodes in the reservation.",
            RES_LABELS,
            registry=registry,
        )
        self.active = Gauge(
            "slurm_reservation_active",
            "1 when the reservation is currently within its time window.",
            RES_LABELS,
            registry=registry,
        )

    async def collect(self) -> None:
        payload = await self._client.get("reservations")
        reservations = safe_iter(payload.get("reservations"))

        for g in (self.start_time, self.end_time, self.node_count, self.active):
            g._metrics.clear()  # type: ignore[attr-defined]

        now = time.time()
        for r in reservations:
            name = str(first_present(r, "name", default="unknown"))
            partition = str(first_present(r, "partition", default=""))
            users = _csv(first_present(r, "users", default=""))
            accounts = _csv(first_present(r, "accounts", default=""))
            start = as_int(first_present(r, "start_time"))
            end = as_int(first_present(r, "end_time"))
            n_nodes = as_int(first_present(r, "node_count"))

            labels = (self._cluster, name, partition, users, accounts)
            self.start_time.labels(*labels).set(start)
            self.end_time.labels(*labels).set(end)
            self.node_count.labels(*labels).set(n_nodes)
            self.active.labels(*labels).set(1.0 if start <= now <= end else 0.0)


def _csv(value: object) -> str:
    if isinstance(value, list):
        return ",".join(str(v) for v in value)
    return str(value or "")
