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
        self.userinfo_down = False
        # Endpoints ("discovery", "jwks", "userinfo") answering 200 with this body.
        self.malformed: dict[str, Any] = {}

    def _malformed(self, endpoint: str) -> httpx.Response | None:
        if endpoint not in self.malformed:
            return None
        body = self.malformed[endpoint]
        if isinstance(body, str):
            return httpx.Response(200, text=body)
        return httpx.Response(200, json=body)

    def jwks(self) -> dict[str, Any]:
        jwk = jwt.algorithms.RSAAlgorithm.to_jwk(self.key.public_key(), as_dict=True)
        return {"keys": [{**jwk, "kid": self.kid, "use": "sig", "alg": "RS256"}]}

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request.url.path)
        if self.down:
            raise httpx.ConnectError("identity provider unreachable")
        path = request.url.path
        if path == "/oauth2/.well-known/openid-configuration":
            return self._malformed("discovery") or httpx.Response(200, json={
                "issuer": ISSUER, "jwks_uri": f"{ISSUER}/jwk",
                "userinfo_endpoint": f"{ISSUER}/userinfo",
            })  # fmt: skip
        if path == "/oauth2/jwk":
            return self._malformed("jwks") or httpx.Response(200, json=self.jwks())
        if path == "/oauth2/userinfo":
            if self.userinfo_down:
                raise httpx.ConnectError("userinfo unreachable")
            if "userinfo" in self.malformed:
                return self._malformed("userinfo")
            token = request.headers.get("Authorization", "").removeprefix("Bearer ")
            claims = self.opaque_tokens.get(token)
            if claims is None:
                return httpx.Response(401, json={"error": "invalid_token"})
            return httpx.Response(200, json=claims)
        return httpx.Response(404)

    def token(self, key=None, kid: str | None = None, **claims: Any) -> str:
        payload: dict[str, Any] = {
            "iss": ISSUER, "sub": "subject-1", "exp": NOW + 600, "iat": NOW - 10,
            "preferred_username": "alice", "aud": CLIENT_ID,
        }  # fmt: skip
        payload.update(claims)
        payload = {name: value for name, value in payload.items() if value is not None}
        return jwt.encode(
            payload, key or self.key, algorithm="RS256", headers={"kid": kid or self.kid}
        )


def oidc_harness(issuer: MockIssuer, static: bool = False, **oidc: Any) -> Harness:
    if not oidc.get("required_entitlements"):
        oidc.setdefault("allow_any_authenticated", True)
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
        # A blank parameter counts as absent.
        blank = (await client.get("/api/v1/queue?user=")).json()["data"]
        assert blank["user"] == "alice"
    # The static token keeps working beside OIDC.
    assert await status(harness, STATIC_TOKEN) == 200
    # The JWKS is fetched once and then cached.
    assert issuer.requests.count("/oauth2/jwk") == 1


async def test_user_star_overrides_the_default_of_the_signed_in_user(issuer):
    harness = oidc_harness(issuer)
    await harness.poll()
    async with harness.client(issuer.token()) as client:
        queue = (await client.get("/api/v1/queue?user=*")).json()["data"]
        assert (queue["user"], queue["mine"], queue["my_jobs"]) == (None, None, [])
        assert queue["my_jobs_total"] == 0 and queue["running"] > 300
        qos = (await client.get("/api/v1/qos?user=*")).json()["data"]
        assert (qos["user"], qos["account"], qos["fairshare"]) == (None, None, None)
        assert qos["qos"]
        runners = (await client.get("/api/v1/runners?user=*")).json()["data"]
        owners = {cluster["owner"] for cluster in runners["dask"]["clusters"]}
        assert "alice" in owners and len(owners) > 1
        assert runners["ci"]["runners_alive"] == 4
        # The identity itself is untouched.
        assert (await client.get("/api/v1/me")).json()["username"] == "alice"


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
    harness = oidc_harness(issuer, audience="https://monitor.example.org")
    assert await status(harness, issuer.token(aud="https://monitor.example.org")) == 200
    assert await status(harness, issuer.token(aud=["other", "https://monitor.example.org"])) == 200
    assert await status(harness, issuer.token(aud="another-client")) == 401
    assert await status(harness, issuer.token(aud=None)) == 401
    # An explicit audience replaces the default rule: the client id no longer does.
    assert await status(harness, issuer.token(aud=CLIENT_ID)) == 401
    assert await status(harness, issuer.token(aud=None, azp="https://monitor.example.org")) == 401


async def test_audience_defaults_to_the_client_id(issuer):
    harness = oidc_harness(issuer)
    assert await status(harness, issuer.token(aud=CLIENT_ID)) == 200
    assert await status(harness, issuer.token(aud=["account", CLIENT_ID])) == 200
    assert await status(harness, issuer.token(aud=None, azp=CLIENT_ID)) == 200
    assert await status(harness, issuer.token(aud="account", azp=CLIENT_ID)) == 200
    assert await status(harness, issuer.token(aud=None, client_id=CLIENT_ID)) == 200
    # A token the same issuer gave to another application, or to nobody in particular.
    assert await status(harness, issuer.token(aud="another-client")) == 401
    assert await status(harness, issuer.token(aud=["a", "b"], azp="another-client")) == 401
    assert await status(harness, issuer.token(aud=None)) == 401
    # The opt-out, for providers whose tokens carry none of the three claims.
    unchecked = oidc_harness(issuer, verify_audience=False)
    assert await status(unchecked, issuer.token(aud=None)) == 200
    assert await status(unchecked, issuer.token(aud="another-client")) == 200


def test_oidc_refuses_to_start_open_to_everyone():
    base = {"enabled": True, "issuer": ISSUER, "client_id": CLIENT_ID}
    with pytest.raises(ValueError, match="allow_any_authenticated"):
        make_settings(auth={"oidc": base})
    with pytest.raises(ValueError, match="required_entitlements"):
        make_settings(auth={"oidc": {**base, "required_entitlements": []}})
    assert make_settings(auth={"oidc": {**base, "required_entitlements": [ENTITLEMENT]}})
    assert make_settings(auth={"oidc": {**base, "allow_any_authenticated": True}})
    # Disabled OIDC needs neither.
    assert make_settings(auth={"oidc": {"enabled": False}})


async def test_required_entitlement(issuer):
    harness = oidc_harness(issuer, required_entitlements=[ENTITLEMENT])
    await harness.poll()
    allowed = issuer.token(eduperson_entitlement=[ENTITLEMENT, "urn:other"])
    by_group = issuer.token(groups=ENTITLEMENT)
    by_entitlements = issuer.token(entitlements=[ENTITLEMENT])
    denied = issuer.token(eduperson_entitlement=["urn:other"])
    assert await status(harness, allowed) == 200
    assert await status(harness, by_group) == 200
    assert await status(harness, by_entitlements) == 200
    assert await status(harness, issuer.token(entitlements=["urn:other"])) == 403
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


# ----- token handling ----------------------------------------------------------


async def test_refused_tokens_are_remembered_for_a_minute():
    issuer = MockIssuer()
    harness = oidc_harness(issuer)
    for _ in range(5):
        assert await status(harness, "garbage-token") == 401
    assert issuer.requests.count("/oauth2/userinfo") == 1
    # The issuer starts to know the token: still refused while remembered …
    issuer.opaque_tokens["garbage-token"] = {"sub": "subject-5", "preferred_username": "erin"}
    harness.clock.now = NOW + 59
    assert await status(harness, "garbage-token") == 401
    assert issuer.requests.count("/oauth2/userinfo") == 1
    # … and asked about again after a minute.
    harness.clock.now = NOW + 61
    assert await status(harness, "garbage-token") == 200
    assert issuer.requests.count("/oauth2/userinfo") == 2
    # A refused JWT is remembered too; another token is not affected by it.
    bad = issuer.token(key=issuer.other_key)
    assert await status(harness, bad) == 401
    assert await status(harness, issuer.token()) == 200


async def test_opaque_tokens_can_be_turned_off():
    issuer = MockIssuer()
    issuer.opaque_tokens["opaque-token-1"] = {"sub": "subject-3", "preferred_username": "carol"}
    assert await status(oidc_harness(issuer), "opaque-token-1") == 200  # the default
    strict = oidc_harness(issuer, accept_opaque_tokens=False)
    before = len(issuer.requests)
    assert await status(strict, "opaque-token-1") == 401
    assert await status(strict, "a.b.c") == 401  # three parts, but not a JWT
    assert len(issuer.requests) == before  # decided without asking the issuer
    assert await status(strict, issuer.token()) == 200


async def test_what_can_be_decided_locally_is_401_while_the_provider_is_down():
    issuer = MockIssuer()
    issuer.down = True
    harness = oidc_harness(issuer)
    for token in (
        "not a token!",
        "über-token",
        "x" * 9000,
        issuer.token(exp=NOW - 120),
        issuer.token(iss="https://elsewhere.example.org"),
        issuer.token(exp=None),
        jwt.encode({"iss": ISSUER, "sub": "x", "exp": NOW + 600}, "secret" * 8, algorithm="HS256"),
    ):
        async with harness.client(token=None) as client:
            response = await client.get(
                "/api/v1/me", headers={"Authorization": b"Bearer " + token.encode()}
            )
        assert response.status_code == 401, token[:40]
    # Not decidable locally: a JWT that may be valid, and an opaque token.
    assert await status(harness, issuer.token()) == 503
    assert await status(harness, "opaque-token-1") == 503
    # With opaque tokens turned off, a non-JWT is refused locally as well.
    strict = oidc_harness(issuer, accept_opaque_tokens=False)
    assert await status(strict, "opaque-token-1") == 401
    assert issuer.requests.count("/oauth2/userinfo") == 0


async def test_stale_jwks_keys_are_used_while_the_provider_is_down():
    issuer = MockIssuer()
    harness = oidc_harness(issuer, jwks_cache_seconds=3600)
    assert await status(harness, issuer.token()) == 200
    issuer.down = True
    harness.clock.now = NOW + 4000  # the cached keys have run out
    fresh = issuer.token(exp=NOW + 9000, iat=NOW + 3990)
    assert await status(harness, fresh) == 200
    assert await status(harness, issuer.token(exp=NOW + 9000, key=issuer.other_key)) == 401
    # A key the server has never seen may be a new one: an outage, not a verdict.
    unknown = issuer.token(exp=NOW + 9000, kid="key-2")
    assert await status(harness, unknown) == 503
    # The provider is not asked again on every request.
    attempts = issuer.requests.count("/oauth2/jwk") + issuer.requests.count(
        "/oauth2/.well-known/openid-configuration"
    )
    assert await status(harness, fresh) == 200
    assert issuer.requests.count("/oauth2/jwk") + issuer.requests.count(
        "/oauth2/.well-known/openid-configuration"
    ) == attempts  # fmt: skip
    # Back again: the keys are refreshed and the new key is known.
    issuer.down = False
    issuer.key, issuer.kid = issuer.other_key, "key-2"
    harness.clock.now = NOW + 4100
    assert await status(harness, issuer.token(exp=NOW + 9000)) == 200


async def test_jwt_without_username_is_accepted_when_userinfo_is_unavailable():
    issuer = MockIssuer()
    issuer.userinfo_down = True
    harness = oidc_harness(issuer)
    nameless = issuer.token(sub="subject-7", preferred_username=None)
    async with harness.client(nameless) as client:
        me = await client.get("/api/v1/me")
    assert me.status_code == 200
    assert me.json() == {"method": "oidc", "subject": "subject-7", "username": None}
    # userinfo answering with a server error is the same case.
    issuer.userinfo_down = False
    issuer.malformed["userinfo"] = "<html>bad gateway</html>"
    other = issuer.token(sub="subject-8", preferred_username=None)
    assert await status(harness, other) == 200

    # A missing entitlement cannot be waved through: that stays an outage.
    guarded = oidc_harness(issuer, required_entitlements=[ENTITLEMENT])
    assert await status(guarded, nameless) == 503
    carrying = issuer.token(preferred_username=None, eduperson_entitlement=[ENTITLEMENT])
    assert await status(guarded, carrying) == 200


async def test_userinfo_subject_must_match_the_jwt_subject():
    issuer = MockIssuer()
    harness = oidc_harness(issuer)
    bare = issuer.token(sub="subject-2", preferred_username=None)
    issuer.opaque_tokens[bare] = {"sub": "somebody-else", "preferred_username": "mallory"}
    assert await status(harness, bare) == 401
    issuer.opaque_tokens[bare] = {"sub": "subject-2", "preferred_username": "bob"}
    harness.clock.now = NOW + 301  # past the userinfo cache and the remembered refusal
    async with harness.client(bare) as client:
        assert (await client.get("/api/v1/me")).json()["username"] == "bob"


@pytest.mark.parametrize(
    ("endpoint", "body"),
    [
        ("discovery", "<html>maintenance</html>"),
        ("discovery", ["not", "an", "object"]),
        ("discovery", {"issuer": ISSUER}),  # no jwks_uri
        ("jwks", "<html>maintenance</html>"),
        ("jwks", {"keys": "none"}),
        ("jwks", [1, 2]),
        ("userinfo", "<html>maintenance</html>"),
        ("userinfo", ["x"]),
        ("userinfo", {"preferred_username": "nobody"}),  # no subject
    ],
)
async def test_malformed_provider_answers_are_an_outage_not_a_crash(endpoint, body):
    issuer = MockIssuer()
    issuer.malformed[endpoint] = body
    harness = oidc_harness(issuer)
    token = "opaque-token-1" if endpoint == "userinfo" else issuer.token()
    async with harness.client(token) as client:
        response = await client.get("/api/v1/me")
    assert response.status_code == 503
    assert response.json() == {"error": "auth_unavailable"}
    # Nothing was remembered as refused: once the provider is well, the token works.
    issuer.malformed.clear()
    issuer.opaque_tokens["opaque-token-1"] = {"sub": "subject-3", "preferred_username": "carol"}
    assert await status(harness, token) == 200


async def test_jwks_entries_that_are_not_keys_are_skipped():
    issuer = MockIssuer()
    issuer.malformed["jwks"] = {"keys": ["junk", {"kty": "unknown"}, *issuer.jwks()["keys"]]}
    assert await status(oidc_harness(issuer), issuer.token()) == 200
