"""Bearer authentication: static tokens and OIDC access tokens."""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import logging
import re
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
# A refused token is remembered this long, so that a client repeating it does
# not cause a request to the identity provider each time.
REJECTION_CACHE_SECONDS = 60
REJECTION_CACHE_MAX_ENTRIES = 4096
MAX_TOKEN_LENGTH = 8192
# RFC 6750: what a bearer token may consist of.
_BEARER_TOKEN = re.compile(r"^[A-Za-z0-9\-._~+/]+=*$")


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


def _decode_segment(segment: str) -> Any:
    padded = segment + "=" * (-len(segment) % 4)
    return json.loads(base64.urlsafe_b64decode(padded.encode("ascii")))


def unverified_jwt(token: str) -> tuple[dict[str, Any], dict[str, Any]] | None:
    """Header and claims of a well-formed JWT, unverified; None for anything else."""
    parts = token.split(".")
    if len(parts) != 3 or not all(parts):
        return None
    try:
        header, claims = _decode_segment(parts[0]), _decode_segment(parts[1])
    except (ValueError, binascii.Error):
        return None
    if not isinstance(header, dict) or not isinstance(claims, dict):
        return None
    if not isinstance(header.get("alg"), str):
        return None
    return header, claims


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


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
        self._keys_attempt_at = float("-inf")
        self._keys_stale = False  # the last attempt to load the keys failed
        self._userinfo_cache: dict[str, tuple[float, dict[str, Any]]] = {}
        self._rejections: dict[str, tuple[float, str]] = {}

    async def close(self) -> None:
        await self._http.aclose()

    # ----- discovery and keys ------------------------------------------------

    async def _get(self, url: str, headers: dict[str, str] | None = None) -> httpx.Response:
        try:
            return await self._http.get(url, headers=headers)
        except (httpx.HTTPError, httpx.InvalidURL) as error:
            raise AuthUnavailable(
                f"identity provider unreachable: {type(error).__name__}"
            ) from error

    @staticmethod
    def _json_object(response: httpx.Response, what: str) -> dict[str, Any]:
        """The body as a JSON object; anything else is the provider's failure."""
        try:
            body = response.json()
        except ValueError as error:
            raise AuthUnavailable(f"{what} is not JSON") from error
        if not isinstance(body, dict):
            raise AuthUnavailable(f"{what} is not a JSON object")
        return body

    async def _discover(self) -> dict[str, Any]:
        age = self._clock() - self._discovery_at
        if self._discovery is not None and age < self._settings.jwks_cache_seconds:
            return self._discovery
        try:
            response = await self._get(f"{self._issuer}/.well-known/openid-configuration")
            if response.status_code != 200:
                raise AuthUnavailable(f"OIDC discovery answered HTTP {response.status_code}")
            document = self._json_object(response, "OIDC discovery document")
            if str(document.get("issuer", "")).rstrip("/") != self._issuer:
                raise AuthUnavailable("OIDC discovery document names a different issuer")
            if not isinstance(document.get("jwks_uri"), str) or not document["jwks_uri"]:
                raise AuthUnavailable("OIDC discovery document has no jwks_uri")
        except AuthUnavailable:
            if self._discovery is None:
                raise
            return self._discovery  # an older document is better than none
        self._discovery = document
        self._discovery_at = self._clock()
        return document

    async def _load_keys(self) -> None:
        discovery = await self._discover()
        response = await self._get(str(discovery["jwks_uri"]))
        if response.status_code != 200:
            raise AuthUnavailable(f"JWKS endpoint answered HTTP {response.status_code}")
        entries = self._json_object(response, "JWKS").get("keys")
        if not isinstance(entries, list):
            raise AuthUnavailable("JWKS has no list of keys")
        keys: dict[str, jwt.PyJWK] = {}
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            try:
                keys[str(entry.get("kid", ""))] = jwt.PyJWK(entry)
            except jwt.PyJWTError:
                continue  # a key type this library cannot use
        self._keys = keys
        self._keys_at = self._clock()

    def _known_key(self, kid: str) -> jwt.PyJWK | None:
        if kid in self._keys:
            return self._keys[kid]
        if not kid and len(self._keys) == 1:
            return next(iter(self._keys.values()))
        return None

    async def _key(self, kid: str) -> jwt.PyJWK | None:
        now = self._clock()
        age = now - self._keys_at
        expired = not self._keys or age > self._settings.jwks_cache_seconds
        # An unknown key id: the issuer may have rotated its keys.
        rotated = self._known_key(kid) is None and age > JWKS_REFETCH_MIN_SECONDS
        recently_tried = now - self._keys_attempt_at < JWKS_REFETCH_MIN_SECONDS
        if (expired or rotated) and not (self._keys and recently_tried):
            self._keys_attempt_at = now
            try:
                await self._load_keys()
                self._keys_stale = False
            except AuthUnavailable as error:
                if not self._keys:
                    raise
                # Signatures can still be checked with the keys already held.
                if not self._keys_stale:
                    logger.warning("JWKS not refreshed, using the keys held: %s", error)
                self._keys_stale = True
        key = self._known_key(kid)
        if key is None and self._keys_stale:
            # The key may be a new one that could not be fetched: not a verdict.
            raise AuthUnavailable("signing key unknown and the JWKS could not be refreshed")
        return key

    # ----- token validation --------------------------------------------------

    def _check_locally(self, claims: dict[str, Any]) -> None:
        """Issuer and time claims; needs neither keys nor the identity provider."""
        if str(claims.get("iss", "")).rstrip("/") != self._issuer:
            raise Unauthorized("token of another issuer")
        now = self._clock()
        expires = claims.get("exp")
        not_before = claims.get("nbf", 0)
        if (
            isinstance(expires, bool)
            or isinstance(not_before, bool)
            or not isinstance(expires, int | float)
            or not isinstance(not_before, int | float)
        ):
            raise Unauthorized("token has unusable time claims")
        if now > expires + CLOCK_LEEWAY_SECONDS or now < not_before - CLOCK_LEEWAY_SECONDS:
            raise Unauthorized("token expired or not yet valid")

    def _check_audience(self, claims: dict[str, Any]) -> None:
        settings = self._settings
        audiences = _as_list(claims.get("aud"))
        if settings.audience:
            if settings.audience not in audiences:
                raise Unauthorized("token is for another audience")
        elif settings.verify_audience:
            named = {*audiences, claims.get("azp"), claims.get("client_id")}
            if settings.client_id not in named:
                raise Unauthorized("token was not issued for this application")

    async def _jwt_claims(
        self, token: str, header: dict[str, Any], unverified: dict[str, Any]
    ) -> dict[str, Any]:
        """Claims of a JWT once its signature, issuer, times and audience hold."""
        algorithm = header.get("alg")
        if algorithm not in ALLOWED_ALGORITHMS:
            raise Unauthorized("signature algorithm not accepted")
        # A token that fails here is refused whatever its signature, so the
        # answer is 401 even while the identity provider cannot be reached.
        self._check_locally(unverified)
        key = await self._key(str(header.get("kid", "")))
        if key is None:
            raise Unauthorized("signing key unknown")
        try:
            claims = jwt.decode(
                token,
                key.key,
                algorithms=[algorithm],
                issuer=[self._issuer, self._issuer + "/"],
                # Times and audience are checked by this class, against the
                # server's own clock and the configured rule.
                options={
                    "require": ["exp", "iss"],
                    "verify_aud": False,
                    "verify_exp": False,
                    "verify_nbf": False,
                    "verify_iat": False,
                },
            )
        except jwt.PyJWTError as error:
            raise Unauthorized(f"token rejected: {type(error).__name__}") from error
        self._check_locally(claims)
        self._check_audience(claims)
        return claims

    async def _userinfo(self, token: str) -> dict[str, Any]:
        cache_key = _token_hash(token)
        now = self._clock()
        cached = self._userinfo_cache.get(cache_key)
        if cached is not None and cached[0] > now:
            return cached[1]
        discovery = await self._discover()
        endpoint = discovery.get("userinfo_endpoint")
        if not isinstance(endpoint, str) or not endpoint:
            raise Unauthorized("issuer has no userinfo endpoint")
        response = await self._get(endpoint, {"Authorization": f"Bearer {token}"})
        if response.status_code in (400, 401, 403):
            raise Unauthorized("userinfo endpoint rejected the token")
        if response.status_code != 200:
            raise AuthUnavailable(f"userinfo endpoint answered HTTP {response.status_code}")
        claims = self._json_object(response, "userinfo answer")
        if not isinstance(claims.get("sub"), str) or not claims["sub"]:
            raise AuthUnavailable("userinfo answer has no subject")
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
        return self._lacks_entitlement_claims(claims)

    def _lacks_entitlement_claims(self, claims: dict[str, Any]) -> bool:
        if not self._settings.required_entitlements:
            return False
        return not any(claims.get(name) for name in ENTITLEMENT_CLAIMS)

    async def _completed_by_userinfo(self, token: str, claims: dict[str, Any]) -> dict[str, Any]:
        """Claims of a valid JWT, with what it lacks taken from userinfo."""
        try:
            extra = await self._userinfo(token)
        except Unauthorized:
            # userinfo refuses, but the signature was valid: go on with the
            # claims the token itself carries.
            return claims
        except AuthUnavailable:
            if not claims.get("sub") or self._lacks_entitlement_claims(claims):
                raise  # whether this person may come in cannot be told now
            # Only the user name is missing: let the person in without one
            # rather than report an outage.
            return claims
        if claims.get("sub") and extra["sub"] != str(claims["sub"]):
            raise Unauthorized("userinfo names a different subject than the token")
        return {**extra, **claims}

    async def _claims(self, token: str) -> dict[str, Any]:
        if len(token) > MAX_TOKEN_LENGTH or not _BEARER_TOKEN.match(token):
            raise Unauthorized("not a bearer token")
        parsed = unverified_jwt(token)
        if parsed is None:
            if not self._settings.accept_opaque_tokens:
                raise Unauthorized("not a JWT, and opaque tokens are not accepted")
            # An opaque token: only the issuer can tell whose it is.
            return await self._userinfo(token)
        claims = await self._jwt_claims(token, *parsed)
        if self._lacks_needed_claims(claims):
            claims = await self._completed_by_userinfo(token, claims)
        return claims

    def _remember_rejection(self, key: str, reason: str) -> None:
        now = self._clock()
        if len(self._rejections) >= REJECTION_CACHE_MAX_ENTRIES:
            self._rejections = {k: v for k, v in self._rejections.items() if v[0] > now}
            if len(self._rejections) >= REJECTION_CACHE_MAX_ENTRIES:
                self._rejections.clear()
        self._rejections[key] = (now + REJECTION_CACHE_SECONDS, reason)

    async def verify(self, token: str) -> Identity:
        key = _token_hash(token)
        rejected = self._rejections.get(key)
        if rejected is not None and rejected[0] > self._clock():
            raise Unauthorized(rejected[1])
        try:
            claims = await self._claims(token)
            subject = str(claims.get("sub") or "")
            if not subject:
                raise Unauthorized("token has no subject")
        except Unauthorized as error:
            self._remember_rejection(key, str(error))
            raise

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
