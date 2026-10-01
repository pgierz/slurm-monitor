"""Synthetic slurmrestd fixtures for the tests.

The generator itself lives in ``slurm_monitor_server.synthetic`` because the
demo mode serves the same cluster. This module pins the seed and the time,
puts the payloads behind a mocked slurmrestd (httpx MockTransport), and
builds applications wired to it.

Fixture forms: ``wrapped`` mimics slurmrestd v0.0.40, ``plain`` mimics
v0.0.38 (see the generator's module documentation).
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

import httpx
from fastapi import FastAPI

from slurm_monitor_server.app import create_app
from slurm_monitor_server.config import Settings
from slurm_monitor_server.gpu_metrics import GpuMetricsSource
from slurm_monitor_server.slurmrestd import SlurmrestdClient, SlurmSourceError
from slurm_monitor_server.synthetic import Form, SyntheticCluster, SyntheticGpuMetrics

SEED = 20261001
NOW = int(datetime(2026, 10, 1, 12, 32, 7, tzinfo=UTC).timestamp())
STATIC_TOKEN = "test-static-token"
SLURM_USER = "monitor"
SLURM_TOKEN = "slurm-jwt-for-tests"
API_VERSIONS: dict[str, str] = {"wrapped": "v0.0.40", "plain": "v0.0.38"}
SAMPLE_USER = "grace"  # few jobs: running and pending both fit the list
BUSY_USER = "alice"  # more jobs than the list holds

CLUSTER = SyntheticCluster(SEED)


class Clock:
    """A settable clock for the poller and the synthetic cluster."""

    def __init__(self, now: int = NOW) -> None:
        self.now = now

    def __call__(self) -> float:
        return float(self.now)


class MockSlurmrestd:
    """A slurmrestd stand-in: checks the Slurm headers and serves the synthetic cluster."""

    def __init__(self, clock: Clock, form: Form = "wrapped") -> None:
        self.clock = clock
        self.form: Form = form
        self.failing = False
        self.requests: list[str] = []

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request.url.path)
        if self.failing:
            return httpx.Response(500, json={"errors": [{"error": "slurmctld unreachable"}]})
        if (
            request.headers.get("X-SLURM-USER-NAME") != SLURM_USER
            or request.headers.get("X-SLURM-USER-TOKEN") != SLURM_TOKEN
        ):
            return httpx.Response(401, json={"errors": [{"error": "Authentication failure"}]})
        version = API_VERSIONS[self.form]
        now = int(self.clock())
        routes = {
            f"/slurm/{version}/jobs": CLUSTER.jobs_payload,
            f"/slurm/{version}/nodes": CLUSTER.nodes_payload,
            f"/slurm/{version}/partitions": CLUSTER.partitions_payload,
            f"/slurmdb/{version}/qos": CLUSTER.qos_payload,
            f"/slurm/{version}/shares": CLUSTER.shares_payload,
        }
        build = routes.get(request.url.path)
        if build is None:
            return httpx.Response(404, json={"errors": [{"error": "not found"}]})
        try:
            return httpx.Response(200, json=build(now, self.form))
        except SlurmSourceError:
            return httpx.Response(404, json={"errors": [{"error": "not found"}]})

    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handle)


def make_settings(form: Form = "wrapped", **overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "cluster": "synthetic",
        "slurm": {
            "base_url": "https://slurm.example.org:6820",
            "api_version": API_VERSIONS[form],
            "user_name": SLURM_USER,
            "token": SLURM_TOKEN,
        },
        "auth": {"static": {"enabled": True, "tokens": [STATIC_TOKEN]}},
        "gpu": {"labels": {"a100": "A100", "a40": "A40"}},
        "runners": {"extra": [{"key": "matlab", "label": "MATLAB", "pattern": "^matlab"}]},
    }
    values.update(overrides)
    return Settings(**values)


class Harness:
    """An application, its mocked slurmrestd and its clock."""

    def __init__(
        self,
        form: Form = "wrapped",
        with_gpu_metrics: bool = False,
        settings: Settings | None = None,
        metrics_source: GpuMetricsSource | None = None,
        oidc_transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.clock = Clock()
        self.settings = settings or make_settings(form)
        self.slurmrestd = MockSlurmrestd(self.clock, form)
        if metrics_source is None and with_gpu_metrics:
            metrics_source = SyntheticGpuMetrics(CLUSTER, self.clock)
        self.app: FastAPI = create_app(
            self.settings,
            source=SlurmrestdClient(self.settings.slurm, transport=self.slurmrestd.transport()),
            metrics_source=metrics_source,
            oidc_transport=oidc_transport,
            clock=self.clock,
            start_poller=False,
        )

    async def poll(self) -> bool:
        return await self.app.state.poller.poll_once()

    def client(self, token: str | None = STATIC_TOKEN) -> httpx.AsyncClient:
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        return httpx.AsyncClient(
            transport=httpx.ASGITransport(app=self.app), base_url="http://server", headers=headers
        )


SAMPLE_REQUESTS: dict[str, tuple[bool, str]] = {
    # sample name → (with GPU metrics, request path)
    "queue": (True, f"/api/v1/queue?user={SAMPLE_USER}"),
    "nodes": (True, "/api/v1/nodes"),
    "qos": (True, f"/api/v1/qos?user={SAMPLE_USER}"),
    "gpu": (True, "/api/v1/gpu"),
    "gpu_no_metrics": (False, "/api/v1/gpu"),
    "runners": (True, "/api/v1/runners"),
}


async def build_contract_samples() -> dict[str, dict[str, Any]]:
    """Full enveloped responses of the server for the synthetic cluster.

    Four polls five minutes apart precede the requests, so that the history
    arrays hold several points.
    """
    samples: dict[str, dict[str, Any]] = {}
    for with_metrics in (True, False):
        harness = Harness("wrapped", with_gpu_metrics=with_metrics)
        for minutes_ago in (15, 10, 5, 0):
            harness.clock.now = NOW - minutes_ago * 60
            assert await harness.poll()
        async with harness.client() as client:
            for name, (wants_metrics, path) in SAMPLE_REQUESTS.items():
                if wants_metrics != with_metrics:
                    continue
                response = await client.get(path)
                assert response.status_code == 200, response.text
                samples[name] = response.json()
    return samples
