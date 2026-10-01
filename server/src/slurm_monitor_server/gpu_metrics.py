"""GPU metrics sources.

Slurm knows which cards are allocated but not what they do. A metrics source
adds utilisation, memory, temperature and power per card. All sources share
one small interface; a failing source never fails a poll, it only turns the
metrics off for that snapshot.
"""

from __future__ import annotations

import asyncio
from collections.abc import Sequence
from typing import Any, Protocol

import httpx

from .config import GpuMetricsSettings
from .records import CardMetrics, GpuMetrics
from .slurm_parsing import parse_float


class GpuMetricsError(Exception):
    """The source could not be read."""


class GpuMetricsSource(Protocol):
    #: False for the 'none' source: snapshots then report metrics_available false.
    provides_metrics: bool

    async def read(self, nodes: Sequence[str]) -> GpuMetrics:
        """Metrics keyed by (node name, card index) for the given GPU nodes."""
        ...

    async def close(self) -> None: ...


class NoGpuMetrics:
    provides_metrics = False

    async def read(self, nodes: Sequence[str]) -> GpuMetrics:
        return {}

    async def close(self) -> None:
        return None


def _rounded(value: float | None) -> int | None:
    return round(value) if value is not None else None


class PrometheusGpuMetrics:
    """Reads DCGM exporter metrics through the Prometheus HTTP API."""

    provides_metrics = True

    UTILISATION = "DCGM_FI_DEV_GPU_UTIL"  # percent
    MEMORY_USED = "DCGM_FI_DEV_FB_USED"  # MiB
    MEMORY_FREE = "DCGM_FI_DEV_FB_FREE"  # MiB
    TEMPERATURE = "DCGM_FI_DEV_GPU_TEMP"  # °C
    POWER = "DCGM_FI_DEV_POWER_USAGE"  # W

    def __init__(
        self, settings: GpuMetricsSettings, transport: httpx.AsyncBaseTransport | None = None
    ) -> None:
        self._settings = settings
        self._http = httpx.AsyncClient(
            base_url=(settings.prometheus_url or "").rstrip("/"),
            timeout=settings.timeout_seconds,
            transport=transport,
        )

    async def close(self) -> None:
        await self._http.aclose()

    async def _query(self, metric: str, nodes: set[str]) -> dict[tuple[str, int], float]:
        matchers = self._settings.prometheus_extra_matchers.strip()
        query = f"{metric}{{{matchers}}}" if matchers else metric
        try:
            response = await self._http.get("/api/v1/query", params={"query": query})
            response.raise_for_status()
            body = response.json()
        except (httpx.HTTPError, ValueError) as error:
            raise GpuMetricsError(f"prometheus query {metric}: {type(error).__name__}") from error
        if not isinstance(body, dict) or body.get("status") != "success":
            raise GpuMetricsError(f"prometheus query {metric}: no success")
        values: dict[tuple[str, int], float] = {}
        for sample in body.get("data", {}).get("result", []):
            labels = sample.get("metric", {})
            node = self._node_name(str(labels.get(self._settings.prometheus_node_label, "")), nodes)
            try:
                index = int(labels.get(self._settings.prometheus_gpu_label, ""))
                value = float(sample["value"][1])
            except (KeyError, IndexError, TypeError, ValueError):
                continue
            if node and value == value:  # skip NaN
                values[(node, index)] = value
        return values

    @staticmethod
    def _node_name(label: str, nodes: set[str]) -> str:
        """Match a label value such as ``gpu-001.example.org:9400`` to a node name."""
        if label in nodes:
            return label
        host = label.split(":", 1)[0]
        if host in nodes:
            return host
        short = host.split(".", 1)[0]
        return short if short in nodes or not nodes else ""

    async def read(self, nodes: Sequence[str]) -> GpuMetrics:
        known = set(nodes)
        names = (self.UTILISATION, self.MEMORY_USED, self.MEMORY_FREE, self.TEMPERATURE, self.POWER)
        utilisation, used, free, temperature, power = await asyncio.gather(
            *(self._query(name, known) for name in names)
        )
        metrics: GpuMetrics = {}
        for key in set(utilisation) | set(used) | set(temperature) | set(power):
            memory_used = used.get(key)
            memory_free = free.get(key)
            percent = utilisation.get(key)
            metrics[key] = CardMetrics(
                utilisation=min(1.0, max(0.0, percent / 100.0)) if percent is not None else None,
                memory_used_mib=_rounded(memory_used),
                memory_total_mib=_rounded(memory_used + memory_free)
                if memory_used is not None and memory_free is not None
                else None,
                temperature_c=_rounded(temperature.get(key)),
                power_w=_rounded(power.get(key)),
            )
        return metrics


class CollectorGpuMetrics:
    """Polls the small collector (server/tools) on every GPU node.

    Expected answer of ``http://{node}:{port}/metrics.json``::

        {"node": "gpu-005", "cards": [{"index": 0, "utilisation": 0.97,
          "memory_used_mib": 36864, "memory_total_mib": 40960,
          "temperature_c": 74, "power_w": 286}]}
    """

    provides_metrics = True

    def __init__(
        self, settings: GpuMetricsSettings, transport: httpx.AsyncBaseTransport | None = None
    ) -> None:
        self._settings = settings
        self._http = httpx.AsyncClient(timeout=settings.timeout_seconds, transport=transport)

    async def close(self) -> None:
        await self._http.aclose()

    async def _read_node(self, node: str) -> GpuMetrics:
        settings = self._settings
        url = f"{settings.collector_scheme}://{node}:{settings.collector_port}/metrics.json"
        response = await self._http.get(url)
        response.raise_for_status()
        body: Any = response.json()
        metrics: GpuMetrics = {}
        for card in body.get("cards", []):
            try:
                index = int(card["index"])
            except (KeyError, TypeError, ValueError):
                continue
            utilisation = parse_float(card.get("utilisation"))
            metrics[(node, index)] = CardMetrics(
                utilisation=min(1.0, max(0.0, utilisation)) if utilisation is not None else None,
                memory_used_mib=_rounded(parse_float(card.get("memory_used_mib"))),
                memory_total_mib=_rounded(parse_float(card.get("memory_total_mib"))),
                temperature_c=_rounded(parse_float(card.get("temperature_c"))),
                power_w=_rounded(parse_float(card.get("power_w"))),
            )
        return metrics

    async def read(self, nodes: Sequence[str]) -> GpuMetrics:
        if not nodes:
            return {}
        results = await asyncio.gather(
            *(self._read_node(node) for node in nodes), return_exceptions=True
        )
        metrics: GpuMetrics = {}
        failures = 0
        for result in results:
            if isinstance(result, BaseException):
                failures += 1
            else:
                metrics.update(result)
        # Single nodes may be down; only a total failure counts as "no metrics".
        if failures == len(nodes):
            raise GpuMetricsError("no GPU node answered the collector request")
        return metrics


def build_gpu_metrics_source(
    settings: GpuMetricsSettings, transport: httpx.AsyncBaseTransport | None = None
) -> GpuMetricsSource:
    if settings.source == "prometheus":
        return PrometheusGpuMetrics(settings, transport)
    if settings.source == "collector":
        return CollectorGpuMetrics(settings, transport)
    return NoGpuMetrics()
