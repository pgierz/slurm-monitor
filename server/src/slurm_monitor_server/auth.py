"""Bearer authentication: static tokens and OIDC access tokens."""

from __future__ import annotations

import contextlib
import hashlib
import hmac
import logging
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

import httpx
import jwt

from .config import AuthSettings, OidcSettings

logger = logging.getLogger(__name__)

# Signature algorithms accepted for OIDC tokens; symmetric ones and "none"
# are never accepted.
ALLOWED_ALGORITHMS = ("RS256", "RS384", "RS512", "PS256", "PS384", "PS512",
                      "ES256", "ES384", "ES512", "EdDSA")  # fmt: skip
ENTITLEMENT_CLAIMS = ("eduperson_entitlement", "entitlements", "groups")
JWKS_REFETCH_MIN_SECONDS = 60
CLOCK_LEEWAY_SECONDS = 30
USERINFO_CACHE_MAX_ENTRIES = 1024


class Unauthorized(Exception):
    """No or no valid credentials: 401."""


class Forbidden(Exception):
    """Valid credentials without the required entitlement: 403."""


class AuthUnavailable(Exception):
    """The identity provider could not be reached: 503."""


@dataclass(frozen=True, slots=True)
class Identity:
    method: str  # "token" or "oidc"
    subject: str
    username: str | None


def _as_list(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list | tuple):
        return [item for item in value if isinstance(item, str)]
    return []


class OidcVerifier:
    """Validates OIDC access tokens against one issuer."""

    def __init__(
        self,
        settings: OidcSettings,
        transport: httpx.AsyncBaseTransport | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._settings = settings
        self._issuer = settings.issuer.rstrip("/")
        self._http = httpx.AsyncClient(timeout=settings.timeout_seconds, transport=transport)
        self._clock = clock
        self._discovery: dict[str, Any] | None = None
        self._discovery_at = 0.0
        self._keys: dict[str, jwt.PyJWK] = {}
        self._keys_at = 0.0
        self._userinfo_cache: dict[str, tuple[float, dict[str, Any]]] = {}

    async def close(self) -> None:
        await self._http.aclose()

    # ----- discovery and keys ------------------------------------------------

    async def _get_json(self, url: str, headers: dict[str, str] | None = None) -> httpx.Response:
        try:
            return await self._http.get(url, headers=headers)
        except httpx.HTTPError as error:
            raise AuthUnavailable(
                f"identity provider unreachable: {type(error).__name__}"
            ) from error

    async def _discover(self) -> dict[str, Any]:
        age = self._clock() - self._discovery_at
        if self._discovery is not None and age < self._settings.jwks_cache_seconds:
            return self._discovery
        response = await self._get_json(f"{self._issuer}/.well-known/openid-configuration")
        if response.status_code != 200:
            raise AuthUnavailable(f"OIDC discovery answered HTTP {response.status_code}")
        document = response.json()
        if str(document.get("issuer", "")).rstrip("/") != self._issuer:
            raise AuthUnavailable("OIDC discovery document names a different issuer")
        self._discovery = document
        self._discovery_at = self._clock()
        return document

    async def _load_keys(self) -> None:
        discovery = await self._discover()
        response = await self._get_json(str(discovery.get("jwks_uri", "")))
        if response.status_code != 200:
            raise AuthUnavailable(f"JWKS endpoint answered HTTP {response.status_code}")
        keys: dict[str, jwt.PyJWK] = {}
        for entry in response.json().get("keys", []):
            try:
                keys[str(entry.get("kid", ""))] = jwt.PyJWK(entry)
            except jwt.PyJWTError:
                continue  # a key type this library cannot use
        self._keys = keys
        self._keys_at = self._clock()

    async def _key(self, kid: str) -> jwt.PyJWK | None:
        age = self._clock() - self._keys_at
        if not self._keys or age > self._settings.jwks_cache_seconds:
            await self._load_keys()
        elif kid not in self._keys and age > JWKS_REFETCH_MIN_SECONDS:
            await self._load_keys()  # the issuer may have rotated its keys
        if kid in self._keys:
            return self._keys[kid]
        if not kid and len(self._keys) == 1:
            return next(iter(self._keys.values()))
        return None

    # ----- token validation --------------------------------------------------

    async def _jwt_claims(self, token: str) -> dict[str, Any] | None:
        """Claims of a valid JWT; None when the token is not a JWT at all."""
        if token.count(".") != 2:
            return None
        try:
            header = jwt.get_unverified_header(token)
        except jwt.PyJWTError:
            return None
        algorithm = header.get("alg")
        if algorithm not in ALLOWED_ALGORITHMS:
            raise Unauthorized("signature algorithm not accepted")
        key = await self._key(str(header.get("kid", "")))
        if key is None:
            raise Unauthorized("signing key unknown")
        try:
            claims = jwt.decode(
                token,
                key.key,
                algorithms=[algorithm],
                issuer=[self._issuer, self._issuer + "/"],
                audience=self._settings.audience,
                # Expiry is checked below against the server's own clock.
                options={
                    "require": ["exp", "iss"],
                    "verify_aud": bool(self._settings.audience),
                    "verify_exp": False,
                    "verify_nbf": False,
                    "verify_iat": False,
                },
            )
        except jwt.PyJWTError as error:
            raise Unauthorized(f"token rejected: {type(error).__name__}") from error
        now = self._clock()
        expires = claims.get("exp")
        not_before = claims.get("nbf", 0)
        if not isinstance(expires, int | float) or not isinstance(not_before, int | float):
            raise Unauthorized("token has unusable time claims")
        if now > expires + CLOCK_LEEWAY_SECONDS or now < not_before - CLOCK_LEEWAY_SECONDS:
            raise Unauthorized("token expired or not yet valid")
        return claims

    async def _userinfo(self, token: str) -> dict[str, Any]:
        cache_key = hashlib.sha256(token.encode()).hexdigest()
        now = self._clock()
        cached = self._userinfo_cache.get(cache_key)
        if cached is not None and cached[0] > now:
            return cached[1]
        discovery = await self._discover()
        endpoint = discovery.get("userinfo_endpoint")
        if not endpoint:
            raise Unauthorized("issuer has no userinfo endpoint")
        response = await self._get_json(str(endpoint), {"Authorization": f"Bearer {token}"})
        if response.status_code in (400, 401, 403):
            raise Unauthorized("userinfo endpoint rejected the token")
        if response.status_code != 200:
            raise AuthUnavailable(f"userinfo endpoint answered HTTP {response.status_code}")
        claims = response.json()
        if not isinstance(claims, dict) or not claims.get("sub"):
            raise Unauthorized("userinfo answer has no subject")
        if len(self._userinfo_cache) >= USERINFO_CACHE_MAX_ENTRIES:
            self._userinfo_cache = {
                key: value for key, value in self._userinfo_cache.items() if value[0] > now
            }
            if len(self._userinfo_cache) >= USERINFO_CACHE_MAX_ENTRIES:
                self._userinfo_cache.clear()
        self._userinfo_cache[cache_key] = (now + self._settings.userinfo_cache_seconds, claims)
        return claims

    def _lacks_needed_claims(self, claims: dict[str, Any]) -> bool:
        if not claims.get("sub") or not claims.get(self._settings.username_claim):
            return True
        if self._settings.required_entitlements:
            return not any(claims.get(name) for name in ENTITLEMENT_CLAIMS)
        return False

    async def verify(self, token: str) -> Identity:
        claims = await self._jwt_claims(token)
        if claims is None:
            # An opaque token: only the issuer can tell whose it is.
            claims = await self._userinfo(token)
        elif self._lacks_needed_claims(claims):
            # When userinfo refuses, the signature was still valid: go on with
            # the claims the token itself carries.
            with contextlib.suppress(Unauthorized):
                claims = {**await self._userinfo(token), **claims}
        subject = str(claims.get("sub") or "")
        if not subject:
            raise Unauthorized("token has no subject")

        required = set(self._settings.required_entitlements)
        if required:
            held = {value for name in ENTITLEMENT_CLAIMS for value in _as_list(claims.get(name))}
            if not held & required:
                raise Forbidden("required entitlement missing")

        claim_value = claims.get(self._settings.username_claim)
        claim_text = claim_value if isinstance(claim_value, str) and claim_value else None
        mapping = self._settings.username_map
        username = mapping.get(subject) or (mapping.get(claim_text) if claim_text else None)
        return Identity(method="oidc", subject=subject, username=username or claim_text)


class Authenticator:
    """Accepts a bearer token by whichever methods are enabled."""

    def __init__(
        self,
        settings: AuthSettings,
        oidc_transport: httpx.AsyncBaseTransport | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._static_tokens = (
            [token.encode() for token in settings.static.tokens if token]
            if settings.static.enabled
            else []
        )
        self._oidc = (
            OidcVerifier(settings.oidc, oidc_transport, clock) if settings.oidc.enabled else None
        )
        self.methods: list[str] = []
        if self._static_tokens:
            self.methods.append("token")
        if self._oidc is not None:
            self.methods.append("oidc")
        if not self.methods:
            logger.warning("no authentication method is enabled; every request will get 401")

    async def close(self) -> None:
        if self._oidc is not None:
            await self._oidc.close()

    def _matches_static(self, token: str) -> bool:
        candidate = token.encode()
        matched = False
        for known in self._static_tokens:  # no early exit: constant time over all tokens
            matched |= hmac.compare_digest(candidate, known)
        return matched

    async def authenticate(self, authorization: str | None) -> Identity:
        if not authorization:
            raise Unauthorized("no credentials")
        scheme, _, token = authorization.partition(" ")
        token = token.strip()
        if scheme.lower() != "bearer" or not token:
            raise Unauthorized("not a bearer token")
        if self._static_tokens and self._matches_static(token):
            return Identity(method="token", subject="static-token", username=None)
        if self._oidc is not None:
            return await self._oidc.verify(token)
        raise Unauthorized("token not accepted")
