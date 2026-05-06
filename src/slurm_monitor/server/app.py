"""Starlette app exposing /metrics, /healthz, /readyz.

Run with::

    python -m slurm_monitor.server.app
    # or
    slurm-monitor-exporter
"""

from __future__ import annotations

import time

import structlog
import uvicorn
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, generate_latest
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse, Response
from starlette.routing import Route

from slurm_monitor import __version__
from slurm_monitor.client import JWTProvider, SlurmrestdClient
from slurm_monitor.collectors import (
    Collector,
    CollectorRunner,
    DiagnosticsCollector,
    JobsCollector,
    NodesCollector,
    PartitionsCollector,
    ReservationsCollector,
    SelfMetrics,
)
from slurm_monitor.config import Settings, load_settings
from slurm_monitor.logging import configure_logging

log = structlog.get_logger("slurm_monitor.server")


def build_app(settings: Settings | None = None) -> Starlette:
    settings = settings or load_settings()
    configure_logging(level=settings.server.log_level, json=settings.server.log_json)

    registry = CollectorRegistry()
    self_metrics = SelfMetrics(registry, cluster=settings.slurm.cluster)
    self_metrics.info.info(
        {
            "version": __version__,
            "cluster": settings.slurm.cluster,
            "slurm_url": str(settings.slurm.base_url),
        }
    )

    jwt = JWTProvider(settings.auth)
    client = SlurmrestdClient(settings.slurm, jwt)

    collectors: list[tuple[Collector, int]] = [
        (NodesCollector(client, self_metrics, registry, settings.slurm.cluster),
         settings.intervals.nodes_seconds),
        (JobsCollector(client, self_metrics, registry, settings.slurm.cluster),
         settings.intervals.jobs_seconds),
        (PartitionsCollector(client, self_metrics, registry, settings.slurm.cluster),
         settings.intervals.partitions_seconds),
        (DiagnosticsCollector(client, self_metrics, registry, settings.slurm.cluster),
         settings.intervals.diag_seconds),
        (ReservationsCollector(client, self_metrics, registry, settings.slurm.cluster),
         settings.intervals.reservations_seconds),
    ]

    runner = CollectorRunner(collectors)
    started_at = time.monotonic()

    async def metrics(_req: Request) -> Response:
        body = generate_latest(registry)
        return Response(body, media_type=CONTENT_TYPE_LATEST)

    async def healthz(_req: Request) -> Response:
        return PlainTextResponse("ok\n")

    async def readyz(_req: Request) -> Response:
        # Permissive during the configured grace window after boot.
        if time.monotonic() - started_at < settings.server.readiness_grace_seconds:
            return PlainTextResponse("starting\n", status_code=200)
        not_ready = []
        for c, interval in collectors:
            stale_after = max(interval * 3, 60)
            if c.last_success == 0:
                not_ready.append({"collector": c.name, "reason": "no successful run"})
            elif time.time() - c.last_success > stale_after:
                not_ready.append(
                    {
                        "collector": c.name,
                        "reason": "stale",
                        "stale_for_s": int(time.time() - c.last_success),
                    }
                )
        if not_ready:
            return JSONResponse({"ready": False, "issues": not_ready}, status_code=503)
        return PlainTextResponse("ready\n")

    async def root(_req: Request) -> Response:
        return PlainTextResponse(
            "slurm-monitor exporter\n"
            f"version={__version__} cluster={settings.slurm.cluster}\n"
            "endpoints: /metrics /healthz /readyz\n"
        )

    routes = [
        Route("/", root),
        Route("/metrics", metrics),
        Route("/healthz", healthz),
        Route("/readyz", readyz),
    ]

    async def on_startup() -> None:
        log.info(
            "exporter.starting",
            version=__version__,
            cluster=settings.slurm.cluster,
            slurm_url=str(settings.slurm.base_url),
            bind=f"{settings.server.bind_host}:{settings.server.bind_port}",
        )
        try:
            api_version = await client.detect_api_version()
            self_metrics.set_api_version(api_version)
        except Exception:
            log.exception("exporter.api_version_probe_failed")
        await runner.start()
        log.info("exporter.started")

    async def on_shutdown() -> None:
        log.info("exporter.stopping")
        await runner.stop()
        await client.aclose()
        log.info("exporter.stopped")

    return Starlette(
        debug=False,
        routes=routes,
        on_startup=[on_startup],
        on_shutdown=[on_shutdown],
    )


def main() -> None:
    settings = load_settings()
    configure_logging(level=settings.server.log_level, json=settings.server.log_json)
    app = build_app(settings)
    uvicorn.run(
        app,
        host=settings.server.bind_host,
        port=settings.server.bind_port,
        log_config=None,
        access_log=False,
        # Slurm exporter is single-process; uvloop optional but not required.
    )


if __name__ == "__main__":
    main()
