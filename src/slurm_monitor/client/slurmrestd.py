"""Async slurmrestd client with version probing and retries."""

from __future__ import annotations

import ssl
from typing import Any

import httpx
import structlog
from tenacity import (
    AsyncRetrying,
    RetryError,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential_jitter,
)

from slurm_monitor.config import SlurmConfig

from .auth import JWTProvider

log = structlog.get_logger(__name__)

# We accept any of these openapi versions exposed by Slurm 22.x slurmrestd.
# Newer wins; we fall back if a probe fails.
SUPPORTED_VERSIONS: tuple[str, ...] = (
    "v0.0.40",
    "v0.0.39",
    "v0.0.38",
    "v0.0.37",
)


class SlurmrestdError(RuntimeError):
    pass


class UnsupportedApiVersionError(SlurmrestdError):
    pass


class SlurmrestdClient:
    """Thin async wrapper for slurmrestd HTTP calls.

    Responsibilities:
      * pick a supported OpenAPI version at startup,
      * inject ``X-SLURM-USER-NAME`` / ``X-SLURM-USER-TOKEN`` on every request,
      * apply bounded retries with jittered backoff,
      * surface clear errors that callers can degrade on.
    """

    def __init__(self, cfg: SlurmConfig, jwt: JWTProvider) -> None:
        self._cfg = cfg
        self._jwt = jwt
        self._api_version: str | None = cfg.api_version
        verify: bool | ssl.SSLContext | str
        if not cfg.verify_tls:
            verify = False
        elif cfg.ca_bundle is not None:
            verify = str(cfg.ca_bundle)
        else:
            verify = True

        self._client = httpx.AsyncClient(
            base_url=str(cfg.base_url).rstrip("/"),
            timeout=cfg.timeout_seconds,
            verify=verify,
            http2=False,
            headers={"Accept": "application/json"},
        )

    @property
    def api_version(self) -> str:
        if self._api_version is None:
            raise SlurmrestdError("API version not yet probed; call detect_api_version() first")
        return self._api_version

    async def aclose(self) -> None:
        await self._client.aclose()

    async def detect_api_version(self) -> str:
        """Pick the highest supported OpenAPI version this slurmrestd serves.

        Strategy: ``GET /openapi/v3``; inspect the ``paths`` dict for
        ``/slurm/<version>/`` prefixes. If the document is unavailable, fall
        back to probing ``/slurm/<version>/ping`` candidates in order.
        """

        if self._cfg.api_version:
            self._api_version = self._cfg.api_version
            log.info("slurmrestd.api_version.pinned", version=self._api_version)
            return self._api_version

        try:
            resp = await self._authed_request("GET", "/openapi/v3")
            doc = resp.json()
            paths = doc.get("paths", {})
            available = {p.split("/")[2] for p in paths if p.startswith("/slurm/v")}
            for v in SUPPORTED_VERSIONS:
                if v in available:
                    self._api_version = v
                    log.info(
                        "slurmrestd.api_version.detected",
                        version=v,
                        candidates=sorted(available),
                    )
                    return v
        except (httpx.HTTPError, ValueError, KeyError) as exc:
            log.warning("slurmrestd.openapi.probe_failed", error=str(exc))

        for v in SUPPORTED_VERSIONS:
            try:
                await self._authed_request("GET", f"/slurm/{v}/ping")
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code in (401, 403):
                    raise
                continue
            except httpx.HTTPError:
                continue
            self._api_version = v
            log.info("slurmrestd.api_version.fallback", version=v)
            return v

        raise UnsupportedApiVersionError(
            f"no supported OpenAPI version among {SUPPORTED_VERSIONS} responded"
        )

    async def get(self, path: str, *, params: dict[str, Any] | None = None) -> dict[str, Any]:
        """GET ``/slurm/<version>/<path>`` with retries; return parsed JSON."""

        full = f"/slurm/{self.api_version}/{path.lstrip('/')}"
        try:
            async for attempt in AsyncRetrying(
                stop=stop_after_attempt(3),
                wait=wait_exponential_jitter(initial=0.5, max=4.0, jitter=0.5),
                retry=retry_if_exception_type((httpx.TransportError, httpx.ReadTimeout)),
                reraise=True,
            ):
                with attempt:
                    resp = await self._authed_request("GET", full, params=params)
                    return resp.json()
        except RetryError as exc:  # pragma: no cover — tenacity reraises by default
            raise SlurmrestdError(f"GET {full} failed after retries: {exc}") from exc
        return {}

    async def _authed_request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
    ) -> httpx.Response:
        token = await self._jwt.get()
        headers = {
            "X-SLURM-USER-NAME": self._jwt.user,
            "X-SLURM-USER-TOKEN": token,
        }
        resp = await self._client.request(method, path, params=params, headers=headers)
        if resp.status_code == 401:
            # Token may have expired between refresh ticks. Force one retry.
            log.info("slurmrestd.auth.refresh_on_401", path=path)
            token = await self._jwt.force_refresh()
            headers["X-SLURM-USER-TOKEN"] = token
            resp = await self._client.request(method, path, params=params, headers=headers)
        resp.raise_for_status()
        return resp
