"""slurmrestd client and Slurm token handling."""

from __future__ import annotations

import asyncio
import shlex
import time
from typing import Any, Protocol

import httpx

from .config import SlurmSettings


class SlurmSourceError(Exception):
    """A payload could not be obtained."""


class SlurmSource(Protocol):
    """Where raw Slurm payloads come from (slurmrestd, or the demo cluster)."""

    async def fetch_jobs(self) -> dict[str, Any]: ...

    async def fetch_nodes(self) -> dict[str, Any]: ...

    async def fetch_partitions(self) -> dict[str, Any]: ...

    async def fetch_qos(self) -> dict[str, Any]: ...

    async def fetch_shares(self) -> dict[str, Any]: ...


class SlurmTokenProvider:
    """Yields the Slurm JWT: from the settings, a file, or a command.

    A token file is read anew on every call, so a cron job may rotate it.
    A token command (``scontrol token lifespan=...``) is run again once its
    result is older than ``token_command_ttl_seconds``.
    """

    def __init__(self, settings: SlurmSettings) -> None:
        self._settings = settings
        self._command_token: str | None = None
        self._command_token_at = 0.0

    async def token(self) -> str:
        settings = self._settings
        if settings.token_file is not None:
            try:
                text = settings.token_file.read_text(encoding="utf-8")
            except OSError as error:
                raise SlurmSourceError(f"token file unreadable: {error.strerror}") from error
            return _clean_token(text)
        if settings.token_command:
            age = time.monotonic() - self._command_token_at
            if self._command_token is None or age > settings.token_command_ttl_seconds:
                self._command_token = await self._run_command(settings.token_command)
                self._command_token_at = time.monotonic()
            return self._command_token
        if settings.token:
            return _clean_token(settings.token)
        raise SlurmSourceError("no Slurm token configured")

    def forget_command_token(self) -> None:
        self._command_token = None

    @staticmethod
    async def _run_command(command: str) -> str:
        process = await asyncio.create_subprocess_exec(
            *shlex.split(command),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, _ = await asyncio.wait_for(process.communicate(), timeout=30)
        except TimeoutError as error:
            process.kill()
            raise SlurmSourceError("token command timed out") from error
        if process.returncode != 0:
            raise SlurmSourceError(f"token command failed with status {process.returncode}")
        token = _clean_token(stdout.decode("utf-8", errors="replace"))
        if not token:
            raise SlurmSourceError("token command gave no token")
        return token


def _clean_token(text: str) -> str:
    """Strip whitespace and the ``SLURM_JWT=`` prefix that scontrol prints."""
    token = text.strip()
    if token.startswith("SLURM_JWT="):
        token = token[len("SLURM_JWT=") :]
    return token.strip()


class SlurmrestdClient:
    """Reads the handful of slurmrestd endpoints the server needs."""

    def __init__(
        self,
        settings: SlurmSettings,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._settings = settings
        self._tokens = SlurmTokenProvider(settings)
        verify: bool | str = str(settings.ca_file) if settings.ca_file else True
        self._http = httpx.AsyncClient(
            base_url=settings.base_url.rstrip("/"),
            timeout=settings.timeout_seconds,
            transport=transport,
            verify=verify,
        )

    async def close(self) -> None:
        await self._http.aclose()

    async def _get(self, path: str) -> dict[str, Any]:
        headers = {
            "X-SLURM-USER-NAME": self._settings.user_name,
            "X-SLURM-USER-TOKEN": await self._tokens.token(),
            "Accept": "application/json",
        }
        try:
            response = await self._http.get(path, headers=headers)
        except httpx.HTTPError as error:
            raise SlurmSourceError(f"{path}: {type(error).__name__}") from error
        if response.status_code == 401:
            # A rotated or expired token: fetch a fresh one on the next poll.
            self._tokens.forget_command_token()
        if response.status_code != 200:
            raise SlurmSourceError(f"{path}: HTTP {response.status_code}")
        try:
            payload = response.json()
        except ValueError as error:
            raise SlurmSourceError(f"{path}: not JSON") from error
        if not isinstance(payload, dict):
            raise SlurmSourceError(f"{path}: unexpected JSON")
        return payload

    async def fetch_jobs(self) -> dict[str, Any]:
        return await self._get(f"/slurm/{self._settings.api_version}/jobs")

    async def fetch_nodes(self) -> dict[str, Any]:
        return await self._get(f"/slurm/{self._settings.api_version}/nodes")

    async def fetch_partitions(self) -> dict[str, Any]:
        return await self._get(f"/slurm/{self._settings.api_version}/partitions")

    async def fetch_qos(self) -> dict[str, Any]:
        return await self._get(f"/slurmdb/{self._settings.effective_db_api_version}/qos")

    async def fetch_shares(self) -> dict[str, Any]:
        # Present from v0.0.40 on; older plugins answer 404 and fairshare
        # is then reported as null.
        return await self._get(f"/slurm/{self._settings.api_version}/shares")
