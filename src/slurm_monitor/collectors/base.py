"""Collector base class and the async runner that drives them on intervals.

Design notes:
  * Collectors write directly to Prometheus ``Gauge`` / ``Counter`` objects.
    The ``/metrics`` HTTP handler is therefore decoupled from slurmrestd
    polling — Prometheus scrapes never trigger Slurm API calls. This is the
    most important reliability property of the whole exporter.
  * Each collector has its own background task and its own interval. A slow
    or failing collector cannot stall the others.
  * Failures are recorded into ``self_metrics`` and degrade gracefully:
    last-known values stay published until the next successful collection.
"""

from __future__ import annotations

import abc
import asyncio
import time
from collections.abc import Callable

import httpx
import structlog

from slurm_monitor.client import SlurmrestdClient
from slurm_monitor.collectors.self_metrics import SelfMetrics

log = structlog.get_logger(__name__)


class Collector(abc.ABC):
    """A single collector responsible for one slurmrestd resource group."""

    name: str

    def __init__(self, client: SlurmrestdClient, self_metrics: SelfMetrics) -> None:
        self._client = client
        self._self = self_metrics
        self._last_success: float = 0.0
        self._last_error: str | None = None

    @abc.abstractmethod
    async def collect(self) -> None:
        """Fetch from slurmrestd and update Prometheus metrics in place."""

    @property
    def last_success(self) -> float:
        return self._last_success

    async def run_once(self) -> None:
        started = time.monotonic()
        try:
            await self.collect()
        except httpx.HTTPStatusError as exc:
            self._last_error = f"http {exc.response.status_code}"
            self._self.record_error(self.name, self._last_error)
            log.warning(
                "collector.error",
                collector=self.name,
                status=exc.response.status_code,
                url=str(exc.request.url),
            )
        except Exception as exc:  # pragma: no cover - defensive top-level
            self._last_error = type(exc).__name__
            self._self.record_error(self.name, self._last_error)
            log.exception("collector.unhandled", collector=self.name)
        else:
            self._last_success = time.time()
            self._last_error = None
            duration = time.monotonic() - started
            self._self.record_success(self.name, duration)
            log.debug("collector.ok", collector=self.name, duration_s=round(duration, 3))


class CollectorRunner:
    """Schedules each collector on its own loop with its own interval."""

    def __init__(
        self,
        collectors: list[tuple[Collector, int]],
        on_first_pass: Callable[[], None] | None = None,
    ) -> None:
        self._items = collectors
        self._on_first_pass = on_first_pass
        self._tasks: list[asyncio.Task] = []
        self._stopping = asyncio.Event()

    async def start(self) -> None:
        # Run one synchronous pass of every collector so /metrics is populated
        # before the first Prometheus scrape, then start the periodic loops.
        await asyncio.gather(*(c.run_once() for c, _ in self._items))
        if self._on_first_pass is not None:
            self._on_first_pass()
        for collector, interval in self._items:
            self._tasks.append(asyncio.create_task(self._loop(collector, interval)))

    async def stop(self) -> None:
        self._stopping.set()
        for t in self._tasks:
            t.cancel()
        for t in self._tasks:
            try:
                await t
            except asyncio.CancelledError:
                pass

    async def _loop(self, collector: Collector, interval: int) -> None:
        while not self._stopping.is_set():
            try:
                await asyncio.wait_for(self._stopping.wait(), timeout=interval)
                return
            except asyncio.TimeoutError:
                pass
            await collector.run_once()
