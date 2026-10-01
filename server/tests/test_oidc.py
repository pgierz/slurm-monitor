"""OIDC authentication with a locally generated RSA key and JWKS."""

from __future__ import annotations

from typing import Any

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from synthetic_cluster import NOW, STATIC_TOKEN, Harness, make_settings

ISSUER = "https://login.example.org/oauth2"
CLIENT_ID = "slurm-monitor-app"
ENTITLEMENT = "urn:geant:example.org:group:hpc-users"


class MockIssuer:
    """An identity provider: discovery document, JWKS and userinfo endpoint."""

    def __init__(self) -> None:
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.other_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.kid = "key-1"
        self.opaque_tokens: dict[str, dict[str, Any]] = {}
        self.requests: list[str] = []
        self.down = False

    def jwks(self) -> dict[str, Any]:
        jwk = jwt.algorithms.RSAAlgorithm.to_jwk(self.key.public_key(), as_dict=True)
        return {"keys": [{**jwk, "kid": self.kid, "use": "sig", "alg": "RS256"}]}

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request.url.path)
        if self.down:
            raise httpx.ConnectError("identity provider unreachable")
        path = request.url.path
        if path == "/oauth2/.well-known/openid-configuration":
            return httpx.Response(200, json={
                "issuer": ISSUER, "jwks_uri": f"{ISSUER}/jwk",
                "userinfo_endpoint": f"{ISSUER}/userinfo",
            })  # fmt: skip
        if path == "/oauth2/jwk":
            return httpx.Response(200, json=self.jwks())
        if path == "/oauth2/userinfo":
            token = request.headers.get("Authorization", "").removeprefix("Bearer ")
            claims = self.opaque_tokens.get(token)
            if claims is None:
                return httpx.Response(401, json={"error": "invalid_token"})
            return httpx.Response(200, json=claims)
        return httpx.Response(404)

    def token(self, key=None, kid: str | None = None, **claims: Any) -> str:
        payload: dict[str, Any] = {
            "iss": ISSUER, "sub": "subject-1", "exp": NOW + 600, "iat": NOW - 10,
            "preferred_username": "alice",
        }  # fmt: skip
        payload.update(claims)
        payload = {name: value for name, value in payload.items() if value is not None}
        return jwt.encode(
            payload, key or self.key, algorithm="RS256", headers={"kid": kid or self.kid}
        )


def oidc_harness(issuer: MockIssuer, static: bool = False, **oidc: Any) -> Harness:
    settings = make_settings(auth={
        "static": {"enabled": static, "tokens": [STATIC_TOKEN]},
        "oidc": {"enabled": True, "issuer": ISSUER, "client_id": CLIENT_ID, **oidc},
    })  # fmt: skip
    return Harness(settings=settings, oidc_transport=httpx.MockTransport(issuer.handle))


async def status(harness: Harness, token: str, path: str = "/api/v1/me") -> int:
    async with harness.client(token) as client:
        return (await client.get(path)).status_code


@pytest.fixture(scope="module")
def issuer() -> MockIssuer:
    return MockIssuer()


async def test_auth_config_lists_oidc(issuer):
    harness = oidc_harness(issuer, static=True)
    async with harness.client(token=None) as client:
        config = (await client.get("/api/v1/auth/config")).json()
    assert config == {
        "methods": ["token", "oidc"],
        "oidc": {"issuer": ISSUER, "client_id": CLIENT_ID,
                 "scopes": ["openid", "profile", "email", "eduperson_entitlement",
                           "offline_access"]},
    }  # fmt: skip


async def test_valid_jwt_is_accepted_and_names_the_user(issuer):
    harness = oidc_harness(issuer, static=True)
    await harness.poll()
    async with harness.client(issuer.token()) as client:
        me = await client.get("/api/v1/me")
        assert me.status_code == 200
        assert me.json() == {"method": "oidc", "subject": "subject-1", "username": "alice"}
        # 'user' defaults to the mapped Slurm user name …
        queue = (await client.get("/api/v1/queue")).json()["data"]
        assert queue["user"] == "alice" and queue["mine"]["running"] > 0
        qos = (await client.get("/api/v1/qos")).json()["data"]
        assert (qos["user"], qos["account"]) == ("alice", "hpc")
        dask = (await client.get("/api/v1/runners")).json()["data"]["dask"]["clusters"]
        assert [c["owner"] for c in dask] == ["alice"]
        # … and an explicit parameter still wins.
        other = (await client.get("/api/v1/queue?user=bob")).json()["data"]
        assert other["user"] == "bob"
    # The static token keeps working beside OIDC.
    assert await status(harness, STATIC_TOKEN) == 200
    # The JWKS is fetched once and then cached.
    assert issuer.requests.count("/oauth2/jwk") == 1


async def test_rejected_jwts(issuer):
    harness = oidc_harness(issuer)
    assert await status(harness, issuer.token(exp=NOW - 120)) == 401
    assert await status(harness, issuer.token(iss="https://elsewhere.example.org")) == 401
    assert await status(harness, issuer.token(key=issuer.other_key)) == 401
    assert await status(harness, issuer.token(exp=None)) == 401
    assert await status(harness, issuer.token(kid="unknown-key")) == 401
    symmetric = jwt.encode(
        {"iss": ISSUER, "sub": "x", "exp": NOW + 600}, "secret" * 8, algorithm="HS256",
        headers={"kid": issuer.kid},
    )  # fmt: skip
    assert await status(harness, symmetric) == 401
    assert await status(harness, issuer.token()) == 200


async def test_expiry_follows_the_clock(issuer):
    harness = oidc_harness(issuer)
    token = issuer.token(exp=NOW + 300)
    assert await status(harness, token) == 200
    harness.clock.now = NOW + 400
    assert await status(harness, token) == 401


async def test_audience_is_checked_when_configured(issuer):
    harness = oidc_harness(issuer, audience=CLIENT_ID)
    assert await status(harness, issuer.token(aud=CLIENT_ID)) == 200
    assert await status(harness, issuer.token(aud=["other", CLIENT_ID])) == 200
    assert await status(harness, issuer.token(aud="another-client")) == 401
    assert await status(harness, issuer.token()) == 401
    unchecked = oidc_harness(issuer)
    assert await status(unchecked, issuer.token(aud="another-client")) == 200


async def test_required_entitlement(issuer):
    harness = oidc_harness(issuer, required_entitlements=[ENTITLEMENT])
    await harness.poll()
    allowed = issuer.token(eduperson_entitlement=[ENTITLEMENT, "urn:other"])
    by_group = issuer.token(groups=ENTITLEMENT)
    denied = issuer.token(eduperson_entitlement=["urn:other"])
    assert await status(harness, allowed) == 200
    assert await status(harness, by_group) == 200
    async with harness.client(denied) as client:
        response = await client.get("/api/v1/queue")
    assert response.status_code == 403
    assert response.json() == {"error": "forbidden"}


async def test_claims_missing_from_the_jwt_come_from_userinfo(issuer):
    harness = oidc_harness(issuer, required_entitlements=[ENTITLEMENT])
    bare = issuer.token(sub="subject-2", preferred_username=None)
    issuer.opaque_tokens[bare] = {
        "sub": "subject-2", "preferred_username": "bob", "eduperson_entitlement": [ENTITLEMENT],
    }  # fmt: skip
    async with harness.client(bare) as client:
        me = await client.get("/api/v1/me")
    assert me.json() == {"method": "oidc", "subject": "subject-2", "username": "bob"}
    del issuer.opaque_tokens[bare]
    # Without userinfo the JWT alone lacks the entitlement.
    fresh = oidc_harness(issuer, required_entitlements=[ENTITLEMENT])
    assert await status(fresh, bare) == 403


async def test_opaque_token_uses_userinfo_with_a_short_cache(issuer):
    harness = oidc_harness(issuer, userinfo_cache_seconds=300)
    issuer.opaque_tokens["opaque-token-1"] = {"sub": "subject-3", "preferred_username": "carol"}
    before = issuer.requests.count("/oauth2/userinfo")
    async with harness.client("opaque-token-1") as client:
        for _ in range(3):
            me = await client.get("/api/v1/me")
            assert me.json() == {"method": "oidc", "subject": "subject-3", "username": "carol"}
        assert issuer.requests.count("/oauth2/userinfo") == before + 1
        harness.clock.now = NOW + 301  # the cache entry has run out
        assert (await client.get("/api/v1/me")).status_code == 200
        assert issuer.requests.count("/oauth2/userinfo") == before + 2
        # A token the issuer withdrew is refused once the cache entry is gone.
        del issuer.opaque_tokens["opaque-token-1"]
        harness.clock.now = NOW + 700
        assert (await client.get("/api/v1/me")).status_code == 401
    assert await status(harness, "opaque-unknown") == 401


async def test_username_claim_and_mapping_table(issuer):
    harness = oidc_harness(
        issuer,
        username_claim="email",
        username_map={"subject-9": "mapped-by-subject", "dave@example.org": "dave"},
    )
    by_claim = issuer.token(email="dave@example.org")
    by_subject = issuer.token(sub="subject-9", email="someone@example.org")
    unmapped = issuer.token(email="erin@example.org")
    for token, expected in (
        (by_claim, "dave"), (by_subject, "mapped-by-subject"), (unmapped, "erin@example.org"),
    ):  # fmt: skip
        async with harness.client(token) as client:
            assert (await client.get("/api/v1/me")).json()["username"] == expected

    # No username claim anywhere: the identity is valid, the username unknown.
    nameless = issuer.token(sub="subject-10")
    async with harness.client(nameless) as client:
        me = (await client.get("/api/v1/me")).json()
    assert me == {"method": "oidc", "subject": "subject-10", "username": None}


async def test_unreachable_identity_provider_gives_503_not_401():
    issuer = MockIssuer()
    issuer.down = True
    harness = oidc_harness(issuer, static=True)
    await harness.poll()
    async with harness.client(issuer.token()) as client:
        response = await client.get("/api/v1/queue")
    assert response.status_code == 503
    assert response.json() == {"error": "auth_unavailable"}
    assert await status(harness, STATIC_TOKEN) == 200


async def test_key_rotation_refetches_the_jwks():
    issuer = MockIssuer()
    harness = oidc_harness(issuer)
    assert await status(harness, issuer.token()) == 200
    issuer.key, issuer.kid = issuer.other_key, "key-2"
    rotated = issuer.token()
    assert await status(harness, rotated) == 401  # refetch is rate-limited
    harness.clock.now = NOW + 120
    assert await status(harness, rotated) == 200
    assert issuer.requests.count("/oauth2/jwk") == 2
