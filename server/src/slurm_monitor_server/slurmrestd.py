"""slurmrestd client and Slurm token handling."""

from __future__ import annotations

import asyncio
import json
import logging
import re
import shlex
import time
from typing import Any, Protocol

import httpx

from .config import SlurmSettings

logger = logging.getLogger(__name__)

# Where slurmrestd serves its OpenAPI document, newest location first.
OPENAPI_PATHS = ("/openapi/v3", "/openapi.json", "/openapi")
# After this many 404 answers in a row for jobs or nodes, a detected API
# version is looked up again: slurmrestd was probably upgraded.
REDETECT_AFTER_NOT_FOUND = 3
_VERSIONED_PATH = re.compile(r"^/(slurm|slurmdb)/(v\d+(?:\.\d+)+)/")


class SlurmSourceError(Exception):
    """A payload could not be obtained."""


class SlurmNotFound(SlurmSourceError):
    """slurmrestd answered 404: the path, and so perhaps the API version, is unknown."""

    def __init__(self, path: str) -> None:
        super().__init__(f"{path}: HTTP 404")


class SlurmSource(Protocol):
    """Where raw Slurm payloads come from (slurmrestd, or the demo cluster)."""

    async def fetch_jobs(self) -> dict[str, Any]: ...

    async def fetch_nodes(self) -> dict[str, Any]: ...

    async def fetch_partitions(self) -> dict[str, Any]: ...

    async def fetch_qos(self) -> dict[str, Any]: ...

    async def fetch_shares(self) -> dict[str, Any]: ...


class SlurmTokenProvider:
    """Yields the Slurm JWT: from the settings, a file, or a command.

    A token file is read anew on every call, so a timer may rotate it.
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


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(number) for number in re.findall(r"\d+", version))


def detect_versions(openapi: Any) -> dict[str, str]:
    """Newest data-parser version per plugin: ``{"slurm": "v0.0.41", "slurmdb": ...}``."""
    found: dict[str, str] = {}
    paths = openapi.get("paths") if isinstance(openapi, dict) else None
    if not isinstance(paths, dict):
        return found
    for path in paths:
        match = _VERSIONED_PATH.match(str(path))
        if match:
            plugin, version = match.groups()
            if plugin not in found or version_key(version) > version_key(found[plugin]):
                found[plugin] = version
    return found


def _parse_payload(content: bytes, path: str) -> dict[str, Any]:
    """Parse a slurmrestd answer; runs in a worker thread."""
    try:
        payload = json.loads(content)
    except ValueError as error:
        raise SlurmSourceError(f"{path}: not JSON") from error
    if not isinstance(payload, dict):
        raise SlurmSourceError(f"{path}: unexpected JSON")
    return payload


def _first_error(payload: dict[str, Any]) -> str | None:
    """Text of the first entry of a non-empty ``errors`` array, else None."""
    errors = payload.get("errors")
    if not isinstance(errors, list) or not errors:
        return None
    first = errors[0]
    if isinstance(first, dict):
        text = first.get("error") or first.get("description") or first.get("error_number")
        return str(text or "unspecified error")[:200]
    return str(first)[:200]


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
        # Versions read from the OpenAPI document; unused where configured.
        self._detected: dict[str, str] = {}
        self._not_found_in_a_row = 0
        if settings.api_version:
            logger.info("slurmrestd API version %s (configured)", settings.api_version)

    async def close(self) -> None:
        await self._http.aclose()

    @property
    def api_version(self) -> str | None:
        """The version in use for /slurm/ paths; None before the first detection."""
        return self._settings.api_version or self._detected.get("slurm")

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
            raise (
                SlurmNotFound(path)
                if response.status_code == 404
                else SlurmSourceError(f"{path}: HTTP {response.status_code}")
            )
        # The jobs payload of a large cluster takes a while to parse; keep
        # that off the event loop so that API requests are answered meanwhile.
        return await asyncio.to_thread(_parse_payload, response.content, path)

    async def _get_data(self, path: str) -> dict[str, Any]:
        """A data payload; an answer that reports errors counts as a failure."""
        payload = await self._get(path)
        error = _first_error(payload)
        if error is not None:
            raise SlurmSourceError(f"{path}: slurmrestd reported: {error}")
        return payload

    async def _detect(self) -> None:
        failures: list[str] = []
        for path in OPENAPI_PATHS:
            try:
                document = await self._get(path)
            except SlurmSourceError as error:
                failures.append(str(error))
                continue
            found = await asyncio.to_thread(detect_versions, document)
            if "slurm" in found:
                found.setdefault("slurmdb", found["slurm"])
                if found != self._detected:
                    logger.info(
                        "slurmrestd API version %s (slurmdb %s), detected from %s",
                        found["slurm"],
                        self._settings.db_api_version or found["slurmdb"],
                        path,
                    )
                self._detected = found
                return
            failures.append(f"{path}: names no /slurm/<version>/ path")
        raise SlurmSourceError(
            "could not detect the slurmrestd API version (" + "; ".join(failures) + "); "
            "set slurm.api_version"
        )

    async def _version(self, plugin: str) -> str:
        settings = self._settings
        configured = settings.api_version
        if plugin == "slurmdb":
            configured = settings.db_api_version or settings.api_version
        if configured:
            return configured
        if plugin not in self._detected:
            await self._detect()
        return self._detected[plugin]

    async def _required(self, resource: str) -> dict[str, Any]:
        """Jobs or nodes. Repeated 404s make a detected version be looked up again."""
        path = f"/slurm/{await self._version('slurm')}/{resource}"
        try:
            payload = await self._get_data(path)
        except SlurmNotFound:
            self._not_found_in_a_row += 1
            if self._not_found_in_a_row >= REDETECT_AFTER_NOT_FOUND and self._detected:
                logger.warning("%s answered 404 repeatedly; detecting the API version again", path)
                self._detected = {}
                self._not_found_in_a_row = 0
            raise
        self._not_found_in_a_row = 0
        return payload

    async def fetch_jobs(self) -> dict[str, Any]:
        return await self._required("jobs")

    async def fetch_nodes(self) -> dict[str, Any]:
        return await self._required("nodes")

    async def fetch_partitions(self) -> dict[str, Any]:
        return await self._get_data(f"/slurm/{await self._version('slurm')}/partitions")

    async def fetch_qos(self) -> dict[str, Any]:
        return await self._get_data(f"/slurmdb/{await self._version('slurmdb')}/qos")

    async def fetch_shares(self) -> dict[str, Any]:
        # Present from v0.0.40 on; older plugins answer 404 and fairshare
        # is then reported as null.
        return await self._get_data(f"/slurm/{await self._version('slurm')}/shares")
