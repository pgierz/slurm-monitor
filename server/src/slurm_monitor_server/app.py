"""The HTTP application."""

import logging
import time
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from typing import Annotated, Any

import httpx
from fastapi import Depends, FastAPI, Header, Query, Request
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel

from . import SCHEMA_VERSION, __version__
from .aggregators import (
    GpuAggregator,
    NodesAggregator,
    QosAggregator,
    QueueAggregator,
    RunnersAggregator,
    iso_timestamp,
)
from .auth import Authenticator, AuthUnavailable, Forbidden, Identity, Unauthorized
from .config import Settings
from .gpu_metrics import GpuMetricsSource, build_gpu_metrics_source
from .models import AuthConfig, Health, Me, OidcClientConfig
from .poller import Poller, SnapshotStore
from .records import ClusterState
from .slurmrestd import SlurmrestdClient, SlurmSource

logger = logging.getLogger(__name__)


class ApiError(Exception):
    def __init__(self, status_code: int, error: str) -> None:
        self.status_code = status_code
        self.error = error


# The value of the 'user' parameter that means "no particular user".
EVERYONE = "*"


def _blank_to_none(value: str | None) -> str | None:
    return value.strip() or None if value is not None else None


def create_app(
    settings: Settings,
    source: SlurmSource | None = None,
    metrics_source: GpuMetricsSource | None = None,
    oidc_transport: httpx.AsyncBaseTransport | None = None,
    clock: Callable[[], float] = time.time,
    start_poller: bool = True,
) -> FastAPI:
    """Build the application.

    ``source`` and ``metrics_source`` default to slurmrestd and the configured
    GPU metrics source; the demo mode and the tests pass their own.
    """
    slurm_source: SlurmSource = source or SlurmrestdClient(settings.slurm)
    gpu_source = metrics_source or build_gpu_metrics_source(settings.gpu.metrics)
    store = SnapshotStore(settings.poll.history_window_seconds)
    poller = Poller(settings, slurm_source, gpu_source, store, clock)
    authenticator = Authenticator(settings.auth, oidc_transport, clock)

    queue_aggregator = QueueAggregator(settings.gpu)
    nodes_aggregator = NodesAggregator()
    qos_aggregator = QosAggregator()
    gpu_aggregator = GpuAggregator(settings.gpu)
    runners_aggregator = RunnersAggregator(settings.runners)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        if start_poller:
            poller.start()
        try:
            yield
        finally:
            await poller.stop()
            await authenticator.close()
            await gpu_source.close()
            close = getattr(slurm_source, "close", None)
            if close is not None:
                await close()

    app = FastAPI(
        title="Slurm Monitor server",
        version=__version__,
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.state.poller = poller
    app.state.store = store

    @app.exception_handler(ApiError)
    async def api_error_handler(request: Request, error: ApiError) -> JSONResponse:
        headers = {"WWW-Authenticate": "Bearer"} if error.status_code == 401 else None
        return JSONResponse({"error": error.error}, status_code=error.status_code, headers=headers)

    async def identity(authorization: Annotated[str | None, Header()] = None) -> Identity:
        try:
            return await authenticator.authenticate(authorization)
        except Unauthorized as error:
            raise ApiError(401, "unauthorized") from error
        except Forbidden as error:
            raise ApiError(403, "forbidden") from error
        except AuthUnavailable as error:
            logger.warning("authentication unavailable: %s", error)
            raise ApiError(503, "auth_unavailable") from error

    Authenticated = Annotated[Identity, Depends(identity)]
    OptionalText = Annotated[str | None, Query(max_length=128)]

    def current_state() -> ClusterState:
        if store.state is None:
            raise ApiError(503, "no_data")
        return store.state

    def envelope(state: ClusterState, data: BaseModel) -> dict[str, Any]:
        return {
            "schema_version": SCHEMA_VERSION,
            "cluster": settings.cluster,
            "generated_at": iso_timestamp(state.polled_at),
            "stale": store.stale,
            "data": data.model_dump(mode="json"),
        }

    def effective_user(who: Identity, user: str | None) -> str | None:
        """Whose jobs count as "mine".

        The 'user' parameter when given; '*' means no particular user. Without
        the parameter, the mapped Slurm user name of an OIDC identity.
        """
        named = _blank_to_none(user)
        if named == EVERYONE:
            return None
        return named or who.username

    @app.get("/api/v1/health")
    async def health() -> dict[str, Any]:
        return Health(
            status="ok",
            version=__version__,
            schema_version=SCHEMA_VERSION,
            last_poll_at=iso_timestamp(store.last_poll_at)
            if store.last_poll_at is not None
            else None,
            last_poll_ok=store.last_poll_ok,
        ).model_dump(mode="json")

    @app.get("/api/v1/auth/config")
    async def auth_config() -> dict[str, Any]:
        oidc = settings.auth.oidc
        return AuthConfig(
            methods=authenticator.methods,  # type: ignore[arg-type]
            oidc=OidcClientConfig(issuer=oidc.issuer, client_id=oidc.client_id, scopes=oidc.scopes)
            if oidc.enabled
            else None,
        ).model_dump(mode="json")

    @app.get("/api/v1/me")
    async def me(who: Authenticated) -> dict[str, Any]:
        return Me(method=who.method, subject=who.subject, username=who.username).model_dump(  # type: ignore[arg-type]
            mode="json"
        )

    @app.get("/api/v1/queue")
    async def queue(
        who: Authenticated,
        partition: OptionalText = None,
        user: OptionalText = None,
        qos: OptionalText = None,
    ) -> dict[str, Any]:
        state = current_state()
        data = queue_aggregator.build(
            state,
            store.history(),
            partition=_blank_to_none(partition),
            qos=_blank_to_none(qos),
            user=effective_user(who, user),
        )
        return envelope(state, data)

    @app.get("/api/v1/nodes")
    async def nodes(who: Authenticated, partition: OptionalText = None) -> dict[str, Any]:
        state = current_state()
        return envelope(state, nodes_aggregator.build(state, _blank_to_none(partition)))

    @app.get("/api/v1/qos")
    async def qos_family(who: Authenticated, user: OptionalText = None) -> dict[str, Any]:
        state = current_state()
        return envelope(state, qos_aggregator.build(state, effective_user(who, user)))

    @app.get("/api/v1/gpu")
    async def gpu(who: Authenticated) -> dict[str, Any]:
        state = current_state()
        return envelope(state, gpu_aggregator.build(state, store.history()))

    @app.get("/api/v1/runners")
    async def runners(who: Authenticated, user: OptionalText = None) -> dict[str, Any]:
        state = current_state()
        return envelope(state, runners_aggregator.build(state, effective_user(who, user)))

    if settings.metrics.enabled:

        @app.get("/metrics")
        async def prometheus_metrics() -> PlainTextResponse:
            return PlainTextResponse(
                render_prometheus(store, nodes_aggregator, gpu_aggregator),
                media_type="text/plain; version=0.0.4",
            )

    return app


def render_prometheus(
    store: SnapshotStore, nodes_aggregator: NodesAggregator, gpu_aggregator: GpuAggregator
) -> str:
    """A handful of gauges in the Prometheus text format."""
    lines: list[str] = []

    def gauge(name: str, help_text: str, samples: list[tuple[str, float]]) -> None:
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} gauge")
        lines.extend(f"{name}{labels} {value:g}" for labels, value in samples)

    gauge("slurm_monitor_last_poll_ok", "1 when the most recent poll succeeded.",
          [("", float(store.last_poll_ok))])  # fmt: skip
    gauge("slurm_monitor_last_poll_timestamp_seconds", "Time of the most recent poll attempt.",
          [("", float(store.last_poll_at or 0))])  # fmt: skip
    state = store.state
    if state is not None:
        running = sum(1 for job in state.jobs if job.state == "R")
        pending = len(state.jobs) - running
        gauge("slurm_monitor_jobs", "Jobs by state.",
              [('{state="running"}', running), ('{state="pending"}', pending)])  # fmt: skip
        nodes = nodes_aggregator.build(state)
        gauge("slurm_monitor_nodes", "Nodes by state.",
              [(f'{{state="{name}"}}', getattr(nodes, name))
               for name in ("allocated", "idle", "drained", "down")])  # fmt: skip
        gpu = gpu_aggregator.build(state, [])
        gauge("slurm_monitor_gpu_cards", "GPU cards in total.", [("", gpu.total)])
        gauge("slurm_monitor_gpu_cards_allocated", "Allocated GPU cards.", [("", gpu.allocated)])
    return "\n".join(lines) + "\n"
