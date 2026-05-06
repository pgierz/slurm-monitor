"""Operator CLI.

The exporter itself runs via ``slurm-monitor-exporter``; this CLI exists for
quick diagnostics and one-shot dumps that ops staff can use without exposing
ports or restarting the service.
"""

from __future__ import annotations

import asyncio
import json
import sys

import click
import structlog

from slurm_monitor import __version__
from slurm_monitor.client import JWTProvider, SlurmrestdClient
from slurm_monitor.config import load_settings
from slurm_monitor.logging import configure_logging
from slurm_monitor.server.app import main as serve_main

log = structlog.get_logger("slurm_monitor.cli")


@click.group(
    help="Operational helpers for the Slurm Prometheus exporter.",
    invoke_without_command=True,
)
@click.version_option(__version__, prog_name="slurm-monitor")
@click.pass_context
def cli(ctx: click.Context) -> None:
    if ctx.invoked_subcommand is None:
        click.echo(ctx.get_help())


@cli.command()
def serve() -> None:
    """Run the exporter (same as `slurm-monitor-exporter`)."""

    serve_main()


@cli.command()
def check() -> None:
    """Probe slurmrestd, refresh the JWT, print the chosen API version."""

    settings = load_settings()
    configure_logging(level="INFO", json=False)

    async def _go() -> int:
        jwt = JWTProvider(settings.auth)
        client = SlurmrestdClient(settings.slurm, jwt)
        try:
            token = await jwt.get()
            click.echo(f"jwt.user        = {jwt.user}")
            click.echo(f"jwt.length      = {len(token)} chars")
            api = await client.detect_api_version()
            click.echo(f"slurmrestd.url  = {settings.slurm.base_url}")
            click.echo(f"slurmrestd.api  = {api}")
            ping = await client.get("ping")
            click.echo("slurmrestd.ping = " + json.dumps(ping)[:200])
            return 0
        except Exception as exc:
            click.echo(f"check failed: {type(exc).__name__}: {exc}", err=True)
            return 1
        finally:
            await client.aclose()

    sys.exit(asyncio.run(_go()))


@cli.command()
@click.argument("resource", type=click.Choice(["nodes", "jobs", "partitions", "diag", "reservations"]))
def dump(resource: str) -> None:
    """Print raw slurmrestd JSON for a single resource. Useful for debugging."""

    settings = load_settings()
    configure_logging(level="INFO", json=False)

    async def _go() -> int:
        jwt = JWTProvider(settings.auth)
        client = SlurmrestdClient(settings.slurm, jwt)
        try:
            await client.detect_api_version()
            payload = await client.get(resource)
            json.dump(payload, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 0
        finally:
            await client.aclose()

    sys.exit(asyncio.run(_go()))


if __name__ == "__main__":
    cli()
