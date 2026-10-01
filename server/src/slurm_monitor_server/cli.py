"""Command line entry point."""

from __future__ import annotations

import argparse
import logging
import os
import time

import uvicorn
from pydantic import ValidationError

from .app import create_app
from .config import CONFIG_ENV_VARIABLE, ExtraRunnerKind, Settings, load_settings
from .synthetic import SyntheticCluster, SyntheticGpuMetrics, SyntheticSlurmSource

DEMO_TOKEN = "demo"


def demo_settings(settings: Settings) -> Settings:
    """Settings of the demo mode: usable without any configuration."""
    if not settings.auth.static.enabled and not settings.auth.oidc.enabled:
        settings.auth.static.enabled = True
        settings.auth.static.tokens = [DEMO_TOKEN]
    if not os.environ.get(CONFIG_ENV_VARIABLE):
        settings.cluster = "demo"
        settings.poll.interval_seconds = 15
        settings.gpu.labels = {"a100": "A100", "a40": "A40"}
        settings.runners.extra = [ExtraRunnerKind(key="matlab", label="MATLAB", pattern="^matlab")]
    return settings


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="slurm-monitor-server",
        description="Middle server between slurmrestd and the Slurm Monitor widgets.",
    )
    parser.add_argument("--config", help=f"TOML configuration file (sets {CONFIG_ENV_VARIABLE})")
    parser.add_argument("--host", help="listen address (overrides the configuration)")
    parser.add_argument("--port", type=int, help="listen port (overrides the configuration)")
    parser.add_argument(
        "--demo",
        action="store_true",
        help="serve a synthetic cluster; no slurmrestd is contacted",
    )
    parser.add_argument("--log-level", default="info")
    arguments = parser.parse_args(argv)

    logging.basicConfig(
        level=arguments.log_level.upper(), format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    if arguments.config:
        os.environ[CONFIG_ENV_VARIABLE] = arguments.config
    try:
        settings = load_settings()
    except ValidationError as error:
        # A misspelt key or a refused combination: say so without a traceback.
        problems = "\n".join(
            f"  {'.'.join(str(part) for part in problem['loc']) or 'settings'}: {problem['msg']}"
            for problem in error.errors()
        )
        parser.exit(2, f"slurm-monitor-server: the configuration is not usable:\n{problems}\n")

    if arguments.demo:
        settings = demo_settings(settings)
        cluster = SyntheticCluster()
        app = create_app(
            settings,
            source=SyntheticSlurmSource(cluster, time.time),
            metrics_source=SyntheticGpuMetrics(cluster, time.time),
        )
        if settings.auth.static.tokens == [DEMO_TOKEN]:
            print(f"Demo mode: synthetic cluster, bearer token '{DEMO_TOKEN}', try user 'alice'.")
    else:
        app = create_app(settings)

    uvicorn.run(
        app,
        host=arguments.host or settings.listen.host,
        port=arguments.port or settings.listen.port,
        log_level=arguments.log_level.lower(),
    )


if __name__ == "__main__":
    main()
