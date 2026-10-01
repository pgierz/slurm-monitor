"""The poller and the store holding its latest result."""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Awaitable, Callable
from typing import Any

from .config import Settings
from .gpu_metrics import GpuMetricsSource
from .history import HistoryPoint, HistoryStore
from .records import ClusterState, GpuMetrics, JobRecord, QosRecord, ShareRecord
from .reduce import (
    RunnerClassifier,
    jobs_without_user_name,
    reduce_jobs,
    reduce_nodes,
    reduce_qos,
    reduce_shares,
)
from .slurmrestd import SlurmSource

logger = logging.getLogger(__name__)

MAX_BACKOFF_SECONDS = 300.0


def poll_delay(interval: float, consecutive_failures: int) -> float:
    """Seconds between two polls: the interval, doubled per failure in a row.

    The doubling stops at five minutes (or at the interval, if that is longer).
    """
    if consecutive_failures <= 0:
        return interval
    doubled = interval * 2 ** min(consecutive_failures, 16)
    return max(interval, min(doubled, MAX_BACKOFF_SECONDS))


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
    """Polls the Slurm source in a background task.

    The interval is fixed while polls succeed and doubles, up to five
    minutes, while they fail.
    """

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
        self.consecutive_failures = 0
        # Whether each optional payload came through last time; None before
        # the first attempt. A change is logged once, not on every poll.
        self._optional_ok: dict[str, bool | None] = {}
        self._last_qos: tuple[QosRecord, ...] = ()
        self._last_shares: tuple[ShareRecord, ...] = ()
        self._warned_empty_user_name = False

    async def poll_once(self) -> bool:
        """One poll; True when a new state was stored."""
        now = int(self._clock())
        try:
            state = await self._collect(now)
        except Exception as error:  # noqa: BLE001 - any failure must leave the old state
            logger.warning("poll failed: %s: %s", type(error).__name__, error)
            self._store.reject(now)
            self.consecutive_failures += 1
            return False
        self._store.accept(state)
        self.consecutive_failures = 0
        return True

    def _reduce_jobs(self, payload: dict[str, Any]) -> tuple[tuple[JobRecord, ...], int]:
        gres_name = self._settings.gpu.gres_name
        return reduce_jobs(payload, self._classifier, gres_name), jobs_without_user_name(payload)

    async def _collect(self, now: int) -> ClusterState:
        gres_name = self._settings.gpu.gres_name
        # Reduction runs in a worker thread, like the JSON parsing before it:
        # the jobs payload of a large cluster keeps a core busy for a while,
        # and API requests must be answered meanwhile. The payload is by far
        # the largest; nothing keeps a reference to it past this statement.
        jobs, nameless = await asyncio.to_thread(self._reduce_jobs, await self._source.fetch_jobs())
        self._note_empty_user_names(nameless)

        partitions_payload = await self._optional(self._source.fetch_partitions, "partitions")
        nodes = await asyncio.to_thread(
            reduce_nodes, await self._source.fetch_nodes(), partitions_payload, gres_name
        )
        del partitions_payload

        # Without a fresh answer the last good QOS limits and shares are kept:
        # they change rarely, and a slurmdbd hiccup should not blank them.
        qos_payload = await self._optional(self._source.fetch_qos, "qos")
        if qos_payload is not None:
            self._last_qos = await asyncio.to_thread(reduce_qos, qos_payload)
        shares_payload = await self._optional(self._source.fetch_shares, "shares")
        if shares_payload is not None:
            self._last_shares = await asyncio.to_thread(reduce_shares, shares_payload)
        del qos_payload, shares_payload

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
            qos=self._last_qos,
            shares=self._last_shares,
            metrics_available=metrics_available,
            gpu_metrics=gpu_metrics,
        )

    def _note_empty_user_names(self, count: int) -> None:
        if count and not self._warned_empty_user_name:
            logger.warning(
                "%d running or pending jobs carry an empty user_name; they are counted for "
                "the cluster but never as anybody's own (slurmrestd could not resolve the "
                "user ids)",
                count,
            )
        self._warned_empty_user_name = bool(count)

    async def _optional(
        self, fetch: Callable[[], Awaitable[dict[str, Any]]], what: str
    ) -> dict[str, Any] | None:
        """Payloads the server can do without: a failure gives None."""
        try:
            payload = await fetch()
        except Exception as error:  # noqa: BLE001
            if self._optional_ok.get(what) is not False:
                logger.warning(
                    "%s not available, going on with what was last known: %s", what, error
                )
            self._optional_ok[what] = False
            return None
        if self._optional_ok.get(what) is False:
            logger.info("%s available again", what)
        self._optional_ok[what] = True
        return payload

    async def run(self) -> None:
        interval = self._settings.poll.interval_seconds
        while True:
            started = time.monotonic()
            await self.poll_once()
            delay = poll_delay(interval, self.consecutive_failures)
            await asyncio.sleep(max(1.0, delay - (time.monotonic() - started)))

    def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self.run(), name="slurm-poller")

    async def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            await asyncio.gather(self._task, return_exceptions=True)
            self._task = None
