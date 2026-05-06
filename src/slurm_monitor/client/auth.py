"""JWT acquisition for slurmrestd.

Three sources are supported, in priority order:

1. ``token_file`` — a file whose contents are the current JWT. Re-read on
   refresh. This is the recommended pattern: a sidecar (cron, systemd timer,
   or another process) keeps the file fresh and the exporter is decoupled
   from how tokens are obtained.
2. ``refresh_command`` — a shell command that prints a fresh token on stdout.
   Most often ``scontrol token lifespan=900`` on a Munge-trusted host.
3. ``token`` — a static token from settings. Useful for short tests only.
"""

from __future__ import annotations

import asyncio
import shlex
import time

import structlog

from slurm_monitor.config import AuthConfig

log = structlog.get_logger(__name__)


class JWTProviderError(RuntimeError):
    pass


class JWTProvider:
    """Caches the current JWT and refreshes on a fixed cadence."""

    def __init__(self, cfg: AuthConfig) -> None:
        self._cfg = cfg
        self._token: str | None = None
        self._fetched_at: float = 0.0
        self._lock = asyncio.Lock()

    @property
    def user(self) -> str:
        return self._cfg.user

    async def get(self) -> str:
        async with self._lock:
            now = time.monotonic()
            if self._token and now - self._fetched_at < self._cfg.refresh_interval_seconds:
                return self._token
            self._token = await self._fetch()
            self._fetched_at = now
            return self._token

    async def force_refresh(self) -> str:
        async with self._lock:
            self._token = await self._fetch()
            self._fetched_at = time.monotonic()
            return self._token

    async def _fetch(self) -> str:
        if self._cfg.token_file is not None:
            try:
                token = self._cfg.token_file.read_text().strip()
            except OSError as exc:
                raise JWTProviderError(f"failed to read token_file: {exc}") from exc
            if not token:
                raise JWTProviderError("token_file is empty")
            log.debug("jwt.refreshed", source="file", path=str(self._cfg.token_file))
            return token

        if self._cfg.refresh_command:
            argv = shlex.split(self._cfg.refresh_command)
            proc = await asyncio.create_subprocess_exec(
                *argv,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await proc.communicate()
            if proc.returncode != 0:
                raise JWTProviderError(
                    f"refresh_command failed (rc={proc.returncode}): {stderr.decode().strip()}"
                )
            token = self._parse_scontrol_token(stdout.decode())
            if not token:
                raise JWTProviderError("refresh_command produced no token")
            log.debug("jwt.refreshed", source="command")
            return token

        if self._cfg.token is not None:
            return self._cfg.token.get_secret_value()

        raise JWTProviderError(
            "no JWT source configured (set SLURM_MONITOR_AUTH_TOKEN_FILE, "
            "SLURM_MONITOR_AUTH_REFRESH_COMMAND, or SLURM_MONITOR_AUTH_TOKEN)"
        )

    @staticmethod
    def _parse_scontrol_token(output: str) -> str:
        # scontrol prints "SLURM_JWT=<token>". Accept either form.
        for line in output.splitlines():
            line = line.strip()
            if line.startswith("SLURM_JWT="):
                return line.split("=", 1)[1].strip()
        return output.strip()
