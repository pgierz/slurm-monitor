# Registering the app with Helmholtz AAI (Helmholtz ID)

What the project owner has to do so that the app can sign in with Helmholtz ID
(`login.helmholtz.de`, a Unity IdM instance). Researched on 2026-10-01 from the
pages listed at the end. Statements are marked **[documented]** when a cited
page says so and **[not verified]** when it does not; the open points are
collected in "Not verified" below and must be settled with the AAI
administrators or by a trial against the development instance.

## What to register

| Item | Value |
|---|---|
| Client type | public client (no secret), native app |
| Flow | authorization code with PKCE (`S256`) |
| Redirect URI | `de.awi.slurm-monitor:/oauth/callback` |
| Scopes | `openid profile email eduperson_entitlement` |
| Client id | free choice at registration; the contract example uses `slurm-monitor-app` |

## Provider facts

| Item | Value | Status |
|---|---|---|
| Issuer | `https://login.helmholtz.de/oauth2` | documented |
| Discovery document | `https://login.helmholtz.de/oauth2/.well-known/openid-configuration` | documented |
| Authorisation endpoint | `https://login.helmholtz.de/oauth2-as/oauth2-authz` | documented |
| Token endpoint | `https://login.helmholtz.de/oauth2/token` | documented |
| Userinfo endpoint | `https://login.helmholtz.de/oauth2/userinfo` | documented |
| JWKS | `https://login.helmholtz.de/oauth2/jwk` | from the discovery document |
| Introspection | `https://login.helmholtz.de/oauth2/introspect` | from the discovery document |
| Revocation | `https://login.helmholtz.de/oauth2/revoke` (needs `token_type_hint`) | documented |
| PKCE methods | `plain`, `S256` | from the discovery document |
| Grant types advertised | `authorization_code`, `implicit` | from the discovery document |
| Development instance | same paths on `https://login-dev.helmholtz.de` | documented |

The discovery document was read through a fetching tool that summarises pages,
not byte for byte; re-read it once with `curl` before fixing the configuration.

## Where and how the registration is requested

**[documented]** Registration is self-service with administrator approval:

1. Open `https://login.helmholtz.de/oauthhome` (for a trial first:
   `https://login-dev.helmholtz.de/oauthhome`).
2. Choose "No account? Sign up." at the top right.
3. Choose "OAuth2/OIDC (OpenID Connect) Client Registration".
4. Fill in the form. The user name becomes the client id, the password the
   client secret. Give the client name shown to users ("Slurm Monitor"), the
   redirect URI and the scopes.
5. Use the comments field for special requirements. The documentation names
   "public client" as such a requirement (its example is a single-page
   application). Write there: native iOS app, public client without secret,
   authorization code flow with PKCE S256, redirect URI with the private
   scheme `de.awi.slurm-monitor:/oauth/callback`.
6. Submit. The AAI administrators review the request before it becomes active.
   Questions go to `support@hifis.net`.

**[documented]** A service must name a security contact who can supply login
information in a security incident, and must have a privacy policy (a
GDPR-compliant template is offered). A service access policy (which virtual
organisations, which assurance level) is optional.

Have ready before starting: the security contact address, the URL of the
privacy policy, a short service description.

## Scopes and claims

**[documented]** on the HIFIS attributes page:

| Claim | Scope | Notes |
|---|---|---|
| `sub` | `openid` | the AAI's own persistent identifier (a UUID) |
| `name`, `given_name`, `family_name` | `profile` | |
| `preferred_username` | `profile` (also `credentials`) | preset from the e-mail prefix, **can be changed by the user** |
| `email`, `email_verified` | `email` | |
| `entitlements` | `entitlements` | group and resource information |
| `eduperson_principal_name` | `eduperson_principal_name` | comes from the home organisation |
| `voperson_id` | `voperson_id` | `<sub without dashes>@<issuer>` |
| `eduperson_assurance` | `eduperson_assurance` | |
| `eduperson_scoped_affiliation` | `eduperson_scoped_affiliation` | |

Scope names requested by the contract:

- `openid`, `profile`, `email`: documented and in the discovery document.
- `eduperson_entitlement`: present in `scopes_supported` of the discovery
  document, requested by the python-social-auth Helmholtz backend, and the
  claim `eduperson_entitlement` appears in the userinfo example of the HIFIS
  oidc-agent page. The HIFIS attributes page, however, lists only the scope
  and claim `entitlements` for OIDC. Both names exist; which claim name a
  client receives for which scope is **[not verified]**. The server should
  read group membership from `eduperson_entitlement` and fall back to
  `entitlements`.

### Group membership

**[documented]** Entitlements are URNs following AARC-G069 (groups) and
AARC-G027 (resource capabilities):

```
urn:geant:helmholtz.de:group:Helmholtz-member#login.helmholtz.de
urn:geant:helmholtz.de:res:HELIPORT#login.helmholtz.de
```

General form: `urn:geant:helmholtz.de:group:<group>[:<subgroup>…][:role=<role>]#login.helmholtz.de`.
The server configuration should hold the exact URN that grants access. Which
group marks users of the cluster (an AWI group, or a virtual organisation
created for the purpose) is a decision for the owner; the URN is
**[not verified]** and must be read from a real userinfo response.

### Username

`preferred_username` is the obvious candidate, but the documentation says the
user can change it, and it is preset from the e-mail prefix, not from the Slurm
account. **It must not be trusted as the Slurm username without a check.**
Options, in order of preference:

1. `eduperson_principal_name` (needs the scope `eduperson_principal_name`,
   which is not in the contract's scope list): comes from the home
   organisation; for AWI users presumably `<account>@awi.de`. The format is
   **[not verified]**.
2. A mapping table in the server configuration from `sub` to Slurm username.
3. `preferred_username`, accepted only as a default for the "mine" filter,
   never for authorisation. Since every signed-in user may see the whole
   queue anyway, this may be acceptable; the owner decides.

This touches `docs/contract.md` (scope list in `/auth/config`); see the report
to the coordinator.

## Access tokens: JWT or opaque

**[not verified]** No HIFIS page states the access token format. Unity IdM can
issue either plain (opaque) or JWT access tokens depending on how the endpoint
is configured, so it has to be looked at:

```sh
# after a trial login, with the access token in $AT
echo "$AT" | awk -F. '{print NF}'      # 3 → JWT, 1 → opaque
curl -s -H "Authorization: Bearer $AT" https://login.helmholtz.de/oauth2/userinfo
```

Consequences for the server:

- Opaque token: only the userinfo fallback works. Cache the userinfo answer
  per token for a few minutes so that widget refreshes do not each cause a
  request to the AAI.
- JWT: validate signature against the JWKS, `iss`, expiry, and check which
  client the token was issued to. Entitlements may be absent from the token
  itself; then userinfo is still needed for the group check.
- The introspection endpoint needs client credentials, which a public client
  does not have; do not plan on it.

Plan for the userinfo path as the one that certainly works.

## Not verified

1. Access token format (JWT or opaque) and access token lifetime.
2. Whether a public client with PKCE is granted for a native app. The
   documentation mentions public clients only for single-page applications;
   `S256` is advertised in the discovery document.
3. Whether a private-scheme redirect URI (`de.awi.slurm-monitor:/oauth/callback`)
   is accepted by the registration form and by Unity's redirect check.
4. Whether the scope `eduperson_entitlement` yields a claim of that name, or
   whether `entitlements` is what is released (see above).
5. Refresh tokens: the documentation ties them to the scope `offline_access`
   together with `prompt=consent`. The contract's scope list has no
   `offline_access`, so without it the user would sign in again whenever the
   access token expires. Whether public clients receive refresh tokens at all
   is not documented.
6. The entitlement URN that identifies cluster users, and the format of
   `eduperson_principal_name` for AWI accounts.
7. The exact fields of the registration form (the steps above are from the
   documentation, not from filling it in) and how long approval takes.
8. The discovery document was not read verbatim (see above); a direct request
   from the work environment was blocked.

Items 1 to 6 can all be settled in one sitting with a trial client on
`login-dev.helmholtz.de`.

## Sources

- HIFIS, Helmholtz AAI, "Service Registration": <https://hifis.net/doc/helmholtz-aai/howto-services-registration/>
- HIFIS, Helmholtz AAI, "Available attributes": <https://hifis.net/doc/helmholtz-aai/attributes/>
- HIFIS, Helmholtz AAI, "oidc-agent" how-to: <https://hifis.net/doc/helmholtz-aai/howto-oidc-agent>
- Discovery document: <https://login.helmholtz.de/oauth2/.well-known/openid-configuration>
- python-social-auth, "Helmholtz AAI (OpenID Connect)" backend: <https://python-social-auth.readthedocs.io/en/latest/backends/helmholtz.html>
