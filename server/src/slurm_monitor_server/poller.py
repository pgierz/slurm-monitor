"""The poller and the store holding its latest result."""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Callable

from .config import Settings
from .gpu_metrics import GpuMetricsSource
from .history import HistoryPoint, HistoryStore
from .records import ClusterState, GpuMetrics
from .reduce import RunnerClassifier, reduce_jobs, reduce_nodes, reduce_qos, reduce_shares
from .slurmrestd import SlurmSource

logger = logging.getLogger(__name__)


class SnapshotStore:
    """The last good cluster state, the outcome of the last poll, and history."""

    def __init__(self, history_window_seconds: int) -> None:
        self._state: ClusterState | None = None
        self._history = HistoryStore(history_window_seconds)
        self.last_poll_at: int | None = None  # time of the most recent attempt
        self.last_poll_ok = False

    @property
    def state(self) -> ClusterState | None:
        return self._state

    @property
    def stale(self) -> bool:
        return self._state is not None and not self.last_poll_ok

    def history(self) -> list[HistoryPoint]:
        return self._history.points()

    def accept(self, state: ClusterState) -> None:
        self._state = state
        self._history.record(state)
        self.last_poll_at = state.polled_at
        self.last_poll_ok = True

    def reject(self, attempted_at: int) -> None:
        self.last_poll_at = attempted_at
        self.last_poll_ok = False


class Poller:
    """Polls the Slurm source at a fixed interval in a background task."""

    def __init__(
        self,
        settings: Settings,
        source: SlurmSource,
        metrics_source: GpuMetricsSource,
        store: SnapshotStore,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._settings = settings
        self._source = source
        self._metrics_source = metrics_source
        self._store = store
        self._clock = clock
        self._classifier = RunnerClassifier(settings.runners)
        self._task: asyncio.Task[None] | None = None

    async def poll_once(self) -> bool:
        """One poll; True when a new state was stored."""
        now = int(self._clock())
        try:
            state = await self._collect(now)
        except Exception as error:  # noqa: BLE001 - any failure must leave the old state
            logger.warning("poll failed: %s: %s", type(error).__name__, error)
            self._store.reject(now)
            return False
        self._store.accept(state)
        return True

    async def _collect(self, now: int) -> ClusterState:
        gres_name = self._settings.gpu.gres_name
        # The jobs payload is by far the largest; it is reduced inside this
        # expression and nothing else keeps a reference to it.
        jobs = reduce_jobs(await self._source.fetch_jobs(), self._classifier, gres_name)

        partitions_payload = await self._optional(self._source.fetch_partitions, "partitions")
        nodes = reduce_nodes(await self._source.fetch_nodes(), partitions_payload, gres_name)
        del partitions_payload

        qos = reduce_qos(await self._optional(self._source.fetch_qos, "qos"))
        shares = reduce_shares(await self._optional(self._source.fetch_shares, "shares"))

        metrics_available = False
        gpu_metrics: GpuMetrics = {}
        if self._metrics_source.provides_metrics:
            gpu_nodes = [node.name for node in nodes if node.gpu_types]
            try:
                gpu_metrics = await self._metrics_source.read(gpu_nodes)
                metrics_available = True
            except Exception as error:  # noqa: BLE001 - metrics never fail a poll
                logger.warning("GPU metrics unavailable: %s: %s", type(error).__name__, error)

        return ClusterState(
            polled_at=now,
            jobs=jobs,
            nodes=nodes,
            qos=qos,
            shares=shares,
            metrics_available=metrics_available,
            gpu_metrics=gpu_metrics,
        )

    @staticmethod
    async def _optional(fetch, what: str):  # type: ignore[no-untyped-def]
        """Payloads the server can do without: a failure gives None."""
        try:
            return await fetch()
        except Exception as error:  # noqa: BLE001
            logger.info("%s not available: %s", what, error)
            return None

    async def run(self) -> None:
        interval = self._settings.poll.interval_seconds
        while True:
            started = time.monotonic()
            await self.poll_once()
            await asyncio.sleep(max(1.0, interval - (time.monotonic() - started)))

    def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self.run(), name="slurm-poller")

    async def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            await asyncio.gather(self._task, return_exceptions=True)
            self._task = None
