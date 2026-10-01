"""Configuration from a TOML file with environment overrides; the demo mode."""

from __future__ import annotations

import tomllib
from pathlib import Path

import httpx
import pytest
from pydantic import BaseModel

from slurm_monitor_server import cli
from slurm_monitor_server.app import create_app
from slurm_monitor_server.config import Settings, load_settings
from slurm_monitor_server.synthetic import (
    SyntheticCluster,
    SyntheticGpuMetrics,
    SyntheticSlurmSource,
)

SERVER_DIRECTORY = Path(__file__).parent.parent
EXAMPLE_CONFIG = SERVER_DIRECTORY / "deploy" / "config.example.toml"


def test_defaults_without_a_file(monkeypatch):
    monkeypatch.delenv("SLURM_MONITOR_CONFIG", raising=False)
    settings = load_settings()
    assert settings.poll.interval_seconds == 60
    assert settings.slurm.api_version == "v0.0.40"
    assert settings.slurm.effective_db_api_version == "v0.0.40"
    assert settings.gpu.metrics.source == "none"
    assert settings.metrics.enabled is False
    assert not settings.auth.static.enabled and not settings.auth.oidc.enabled
    assert settings.runners.ci_pattern == r"^ci-\d+"
    assert settings.runners.dask_pattern == r"^dask-gateway"
    assert settings.runners.jupyterhub_pattern == r"^(spawner-)?jupyterhub"


def test_file_and_environment_overrides(monkeypatch, tmp_path):
    config = tmp_path / "config.toml"
    config.write_text(
        """
cluster = "example"

[slurm]
base_url = "https://slurm.example.org:6820"
api_version = "v0.0.41"
user_name = "monitor"
token = "from-file"

[poll]
interval_seconds = 30

[[runners.extra]]
key = "matlab"
label = "MATLAB"
pattern = "^matlab"

[auth.static]
enabled = true
tokens = ["file-token"]
"""
    )
    monkeypatch.setenv("SLURM_MONITOR_CONFIG", str(config))
    monkeypatch.setenv("SLURM_MONITOR_SLURM__TOKEN", "from-environment")
    monkeypatch.setenv("SLURM_MONITOR_AUTH__STATIC__TOKENS", '["env-token-1", "env-token-2"]')
    settings = load_settings()
    assert settings.cluster == "example"
    assert settings.slurm.api_version == "v0.0.41"
    assert settings.slurm.user_name == "monitor"
    assert settings.slurm.token == "from-environment"
    assert settings.poll.interval_seconds == 30
    assert settings.runners.extra[0].key == "matlab"
    assert settings.auth.static.tokens == ["env-token-1", "env-token-2"]


def test_missing_file_is_an_error(monkeypatch, tmp_path):
    monkeypatch.setenv("SLURM_MONITOR_CONFIG", str(tmp_path / "absent.toml"))
    with pytest.raises(FileNotFoundError):
        load_settings()


def test_invalid_values_are_refused():
    with pytest.raises(ValueError):
        Settings(runners={"ci_pattern": "("})
    with pytest.raises(ValueError):
        Settings(auth={"oidc": {"enabled": True}})
    with pytest.raises(ValueError):
        Settings(poll={"interval_seconds": 0})


def test_example_configuration_loads_and_documents_every_setting(monkeypatch):
    monkeypatch.setenv("SLURM_MONITOR_CONFIG", str(EXAMPLE_CONFIG))
    settings = load_settings()
    assert settings.slurm.base_url == "https://slurm.example.org:6820"

    text = EXAMPLE_CONFIG.read_text()
    parsed = tomllib.loads(text)

    def names(model, prefix=""):
        for name in type(model).model_fields:
            value = getattr(model, name)
            if isinstance(value, BaseModel):
                yield from names(value, f"{prefix}{name}.")
            else:
                yield f"{prefix}{name}", name

    # Every setting appears in the example, set or commented out.
    missing = [path for path, name in names(Settings()) if name not in text]
    assert missing == []
    assert "runners" in parsed and "auth" in parsed


async def test_demo_mode_serves_the_synthetic_cluster_and_varies(monkeypatch):
    monkeypatch.delenv("SLURM_MONITOR_CONFIG", raising=False)
    settings = cli.demo_settings(Settings())
    assert settings.auth.static.tokens == [cli.DEMO_TOKEN]
    now = [1_790_000_000]
    cluster = SyntheticCluster()
    app = create_app(
        settings,
        source=SyntheticSlurmSource(cluster, lambda: now[0]),
        metrics_source=SyntheticGpuMetrics(cluster, lambda: now[0]),
        clock=lambda: now[0],
        start_poller=False,
    )
    snapshots = []
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://server",
        headers={"Authorization": f"Bearer {cli.DEMO_TOKEN}"},
    ) as client:  # fmt: skip
        for _ in range(3):
            assert await app.state.poller.poll_once()
            queue = (await client.get("/api/v1/queue?user=alice")).json()
            gpu = (await client.get("/api/v1/gpu")).json()
            assert queue["cluster"] == "demo" and gpu["data"]["metrics_available"] is True
            snapshots.append((queue["data"]["running"], queue["data"]["pending"],
                              queue["data"]["my_jobs"][0]["elapsed_seconds"]))  # fmt: skip
            now[0] += 1800
    assert len(set(snapshots)) == 3


def test_command_line_help(capsys):
    with pytest.raises(SystemExit):
        cli.main(["--help"])
    assert "--demo" in capsys.readouterr().out
