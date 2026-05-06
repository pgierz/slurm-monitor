import os
from pathlib import Path

import pytest

from slurm_monitor.config import load_settings


@pytest.fixture
def clean_env(monkeypatch):
    for k in list(os.environ):
        if k.startswith("SLURM_MONITOR_"):
            monkeypatch.delenv(k, raising=False)
    yield monkeypatch


def test_defaults_are_sensible(clean_env):
    s = load_settings()
    assert s.slurm.cluster == "albedo"
    assert s.server.bind_port == 9817
    assert s.intervals.nodes_seconds >= 5


def test_env_overrides_yaml(tmp_path: Path, clean_env):
    yml = tmp_path / "config.yml"
    yml.write_text(
        "slurm:\n"
        "  cluster: yaml-cluster\n"
        "  base_url: http://yaml:6820\n"
        "intervals:\n"
        "  jobs_seconds: 10\n"
    )
    clean_env.setenv("SLURM_MONITOR_CONFIG_FILE", str(yml))
    clean_env.setenv("SLURM_MONITOR_SLURM_CLUSTER", "env-wins")
    s = load_settings()
    assert s.slurm.cluster == "env-wins"
    assert str(s.slurm.base_url).startswith("http://yaml:6820")
    assert s.intervals.jobs_seconds == 10


def test_auth_token_file_path(tmp_path: Path, clean_env):
    tf = tmp_path / "jwt"
    tf.write_text("dummy")
    clean_env.setenv("SLURM_MONITOR_AUTH_TOKEN_FILE", str(tf))
    s = load_settings()
    assert s.auth.token_file == tf
