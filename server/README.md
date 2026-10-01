# Slurm Monitor server

The middle server between slurmrestd and the Slurm Monitor widgets. It polls
slurmrestd about once a minute, reduces the large payloads to compact records,
keeps a few hours of history in memory, and serves small JSON snapshots per
widget family. The shapes it serves are fixed by `docs/contract.md`; that
document decides.

It is meant to run inside the institute network. Clients reach it over VPN.

```
slurmrestd ──poll──▶ compact records ──▶ aggregators ──▶ /api/v1/{queue,nodes,qos,gpu,runners}
                         │
GPU metrics source ──────┘   (none | prometheus | collector)
```

## Try it without a cluster

```sh
cd server
uv sync
uv run slurm-monitor-server --demo
```

The demo mode serves a synthetic cluster (240 nodes, partitions mpp, smp, fat
and gpu, A40 and A100 cards, CI runners, Dask clusters, JupyterHub sessions)
that changes slowly with time. No slurmrestd is contacted. Without a
configuration file the bearer token is `demo`:

```sh
curl -H 'Authorization: Bearer demo' 'http://127.0.0.1:8080/api/v1/queue?user=alice'
curl -H 'Authorization: Bearer demo' 'http://127.0.0.1:8080/api/v1/gpu'
```

Synthetic users are `alice`, `bob`, `carol` and so on; `alice` owns a Dask
cluster, `grace` has only a few jobs. To let a phone on the same network reach
the demo, add `--host 0.0.0.0`.

## Install

Python 3.11 or newer.

```sh
python3 -m venv /opt/slurm-monitor/venv
/opt/slurm-monitor/venv/bin/pip install ./server
```

or build the container image with `deploy/Containerfile` (the build command is
at the top of that file). The image installs the dependencies exactly as
recorded in `uv.lock` (`uv sync --frozen`), so it holds the versions the tests
ran with; the `pip install` above resolves afresh within the ranges of
`pyproject.toml`. `deploy/slurm-monitor-server.service` is a systemd unit for
the virtual-environment install.

A misspelt or unknown key in the configuration file is an error at start-up,
not something silently ignored.

## Configure

One TOML file, named by the environment variable `SLURM_MONITOR_CONFIG` (or
`--config`). `deploy/config.example.toml` documents every setting. Any setting
can be overridden in the environment as `SLURM_MONITOR_<SECTION>__<KEY>`; the
environment wins over the file. Use that for secrets:

```sh
SLURM_MONITOR_CONFIG=/etc/slurm-monitor/config.toml
SLURM_MONITOR_SLURM__TOKEN=...                      # only if no token_file / token_command
SLURM_MONITOR_AUTH__STATIC__TOKENS='["a-long-random-string"]'
```

The least a real deployment needs:

```toml
cluster = "example"

[slurm]
base_url = "https://slurm.example.org:6820"
user_name = "slurm-monitor"
token_file = "/run/slurm-monitor/slurm.jwt"

[auth.static]
enabled = true                   # tokens from the environment
```

### API version

slurmrestd puts a data-parser version into every path
(`/slurm/v0.0.41/jobs`), and each Slurm release offers a different handful of
them. Leave `slurm.api_version` unset: the server reads the slurmrestd's
OpenAPI document (`/openapi/v3`, else `/openapi.json`, else `/openapi`) before
its first poll, takes the newest version offered, separately for `slurm` and
`slurmdb`, and logs it. When jobs or nodes answer 404 three times in a row,
as after a Slurm upgrade that dropped the version in use, it looks again. The
version in use is shown as `slurm_api_version` by `/api/v1/health`.

Set `api_version` (and, if it differs, `db_api_version`) only to hold the
server to one version; `slurmrestd -d list` shows what yours offers. A fixed
version is never changed by the server.

### What the Slurm user must be able to see

The server reads `/slurm/{v}/jobs`, `/slurm/{v}/nodes`, `/slurm/{v}/partitions`,
`/slurmdb/{v}/qos` and `/slurm/{v}/shares`. With `PrivateData` set in
`slurm.conf`, an ordinary user sees only its own jobs and shares; the Slurm
user of this server then needs operator rights (or to be the `SlurmUser`) for
the cluster-wide figures to be right.

Jobs and nodes are required: when either fails, the poll fails, and the server
keeps answering from the last good poll with `"stale": true`. While polls fail
the interval between them doubles, up to five minutes; the first success
brings it back to `poll.interval_seconds`.

Partitions, QOS and shares are optional. When the QOS or the shares request
fails, the last good QOS limits and shares are kept; when it never succeeded
(older than v0.0.40, or no slurmdbd) the limits or `fairshare` are `null`.
The log says so once when such a request starts failing and once when it
works again, not on every poll. An answer with HTTP 200 whose `errors` array
is not empty counts as a failure, for every request.

JSON parsing and the reduction of the payloads run in a worker thread, so the
API keeps answering during the poll of a large cluster.

### Token rotation

Slurm JWTs expire. Three ways to supply one, in order of preference:

1. **A token file, rotated by a systemd timer.** The file is read anew on
   every poll, so nothing needs restarting. `deploy/` holds the pair:

   - `slurm-monitor-token.service`, a oneshot unit that runs
     `scontrol token username=slurm-monitor lifespan=7200` as root and writes
     the result to `/run/slurm-monitor/slurm.jwt` (mode 0600, owned by the
     server's user, written to a second file and renamed);
   - `slurm-monitor-token.timer`, which starts it 30 seconds after boot and
     every 30 minutes after that (`OnBootSec=30s`, `OnUnitActiveSec=30min`).

   ```sh
   install -m 0644 deploy/slurm-monitor-token.service deploy/slurm-monitor-token.timer \
       /etc/systemd/system/
   systemctl daemon-reload && systemctl enable --now slurm-monitor-token.timer
   ```

   The token unit is ordered before `slurm-monitor-server.service`, and the
   server unit asks for it, so at boot the token is there before the first
   poll. `/run` is empty after a reboot, which is why a cron job every half
   hour is not enough. The lifespan is four times the timer's period, so a
   few missed runs do no harm. The `SLURM_JWT=` prefix may also be left in
   the file; the server strips it. Adapt the user name and the lifespan in
   the unit; the host needs `scontrol` and a readable Slurm configuration.

   The token file must be readable by the user the server runs as. With the
   container image that is uid 10001 inside the container, not a user of the
   host: mount `/run/slurm-monitor` read-only into the container and either
   `chown 10001` the file in the token unit (rootful podman or docker), or
   run the container with `--user` set to the uid that owns the file
   (rootless podman maps uids; `--userns=keep-id` keeps yours). A poll that
   fails with "token file unreadable" in the log is this.

2. **A token command**, run by the server itself and re-run every
   `token_command_ttl_seconds` (and after a 401 from slurmrestd):

   ```toml
   token_command = "scontrol token lifespan=7200"
   token_command_ttl_seconds = 1800
   ```

   This needs `scontrol` and a readable Slurm configuration where the server
   runs, and the service must run as the Slurm user named in `user_name`.

3. **A fixed token** in `SLURM_MONITOR_SLURM__TOKEN`, for trials only.

### Authentication of the app

Two methods, enabled independently; a request is accepted when either accepts
its bearer token.

- **Static token** (`[auth.static]`): one or more shared secrets, compared in
  constant time. The app then sends the Slurm user name it should treat as
  "mine" as the `user` parameter.
- **OIDC** (`[auth.oidc]`): access tokens of one issuer, for example the
  Helmholtz AAI. The Slurm user name comes from `username_claim` (default
  `preferred_username`), or from `username_map` where that claim differs from
  the cluster account. With OIDC, `user` defaults to that name. `user=*` asks
  for no particular user (the whole cluster's view), with either method.

If no method is enabled, every request to a protected endpoint gets 401.

#### Who is let in with OIDC

- **Entitlement.** `required_entitlements` names the values of which an
  identity must hold at least one (in `eduperson_entitlement`, `entitlements`
  or `groups`); anyone else gets 403. With OIDC enabled the server refuses to
  start while the list is empty, because an issuer such as the Helmholtz AAI
  authenticates far more people than may see this cluster. To accept
  everyone the issuer knows on purpose, set `allow_any_authenticated = true`.
- **Audience.** A JWT access token must be meant for this application: its
  `aud` claim (a string or a list), its `azp` claim or its `client_id` claim
  must name the configured `client_id`. With `audience` set, `aud` must name
  that value instead. For a provider whose access tokens carry none of the
  three claims there is `verify_audience = false`; this weakens the check,
  since a token the issuer gave to any other application is then accepted
  here as well.
- **Opaque tokens cannot be audience-checked.** A string that is not a
  well-formed JWT is taken for an opaque access token and resolved through
  the issuer's userinfo endpoint (cached for `userinfo_cache_seconds`).
  Userinfo tells whose token it is, not which application it was issued to,
  so any valid access token of the issuer passes, subject to the entitlement.
  This is on by default (`accept_opaque_tokens = true`) because the format of
  the Helmholtz AAI's access tokens is not yet confirmed
  (`docs/helmholtz-aai.md`). Once they are known to be JWTs, set it to
  `false`: anything that is not a JWT is then refused at once.
- **Any signed-in user may ask for another user's view** with
  `user=<name>`, and for the whole cluster's with `user=*`. The server is a
  read-only status display. It reads Slurm with one service account and does
  not enforce Slurm's `PrivateData`: what that account can see, every person
  who is let in can see. If that is not acceptable at your site, do not
  give the service account more than an ordinary user's view.

#### How tokens are checked

JWT access tokens are validated against the issuer's JWKS: signature (RSA,
ECDSA or EdDSA only), issuer, expiry and audience. A JWT that lacks the
subject, the user name claim or the entitlement claims is completed from
userinfo; the subject userinfo gives must be the token's own.

- A refused token is remembered by its hash for 60 seconds, so a client that
  repeats a bad token does not cause a request to the issuer each time.
- When the issuer cannot be reached, the answer is `503
  {"error": "auth_unavailable"}` rather than 401, so that the app does not
  ask the person to sign in again because of an outage. The same answer is
  given when the issuer's discovery document, JWKS or userinfo answer is
  malformed.
- What can be decided without the issuer still is: a token that is expired,
  names another issuer, uses a signature algorithm that is not accepted, or
  is not a bearer token at all gets 401 during an outage too, and so does a
  non-JWT when `accept_opaque_tokens` is false.
- The JWKS is cached for `jwks_cache_seconds`. When it cannot be refreshed,
  the keys already held keep being used, so signed-in people stay signed in
  through an outage of the issuer.
- A JWT with a valid signature that only lacks the user name is accepted
  without one when userinfo cannot be reached (`username` is then `null`
  and the app falls back to the name in its settings). If the entitlement is
  what is missing, the answer is 503: that cannot be decided without the
  issuer.

The server speaks plain HTTP; put it behind the institute's reverse proxy for
TLS.

### GPU metrics

Slurm knows which cards are allocated, not what they do. `[gpu.metrics]`
selects where utilisation, memory, temperature and power come from:

| `source` | Meaning |
|---|---|
| `none` | Allocation only. `metrics_available` is false. |
| `prometheus` | DCGM exporter metrics (`DCGM_FI_DEV_GPU_UTIL`, `_FB_USED`, `_FB_FREE`, `_GPU_TEMP`, `_POWER_USAGE`) through a Prometheus HTTP API. The labels carrying node name and card index are configurable. |
| `collector` | The collector in `server/tools`, polled on every GPU node at `http://{node}:{port}/metrics.json`. |

A failing metrics source never fails a poll; that snapshot is served with
`metrics_available` false.

### Runner kinds

CI runners, Dask clusters and JupyterHub sessions are recognised by regular
expressions on the job name (`[runners]`). Dask jobs are grouped into
clusters by a job field (default `comment`, falling back to the owner); the
scheduler is the job whose name or command matches `dask_scheduler_pattern`.
Look at real job names first (`server/tools` has a script that records
slurmrestd payloads) and set the patterns to match.

## Run

```sh
SLURM_MONITOR_CONFIG=/etc/slurm-monitor/config.toml slurm-monitor-server
slurm-monitor-server --config ./config.toml --host 0.0.0.0 --port 8080
```

Check it:

```sh
curl http://127.0.0.1:8080/api/v1/health
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8080/api/v1/nodes
```

`last_poll_ok` in the health answer tells whether the most recent poll
succeeded; the reason for a failure is in the log. Before the first successful
poll the family endpoints answer `503 {"error": "no_data"}`. Every error
answer has the shape `{"error": "<code>"}`; the codes are listed in
`docs/contract.md`.

The log warns once when jobs arrive with an empty `user_name` (slurmrestd
could not resolve user ids, usually a missing user database on its host):
such jobs count for the cluster but never as anybody's own.

With `[metrics] enabled = true` the server also offers `/metrics` in the
Prometheus text format (a handful of gauges, no authentication).

## Develop

```sh
uv sync
uv run pytest
uv run ruff check . && uv run ruff format --check .
```

The tests run against a synthetic cluster (`src/slurm_monitor_server/synthetic.py`,
also used by the demo mode) served through a mocked slurmrestd in two JSON
forms: `wrapped` mimics v0.0.40 (numbers as `{"set", "infinite", "number"}`
objects, states as lists), `plain` mimics v0.0.38 (plain numbers, state
strings, no shares endpoint).

`tests/data/contract_samples/*.json` are full responses of the server for that
cluster; the Swift tests decode them. After a change that alters the output:

```sh
uv run python tests/make_contract_samples.py
```

A test fails while the committed samples are out of date.

### Layout

| Module | Purpose |
|---|---|
| `config.py` | settings: TOML file plus environment |
| `slurmrestd.py` | slurmrestd client, Slurm token handling |
| `slurm_parsing.py` | tolerant helpers for slurmrestd's differing JSON forms |
| `reduce.py` | raw payloads → compact records |
| `records.py` | the compact records |
| `poller.py` | background poll, `SnapshotStore` |
| `history.py` | five-minute history, at most 72 points |
| `aggregators.py` | records → the five families |
| `gpu_metrics.py` | GPU metrics sources |
| `auth.py` | static token and OIDC |
| `models.py` | response models (the contract's shapes) |
| `app.py`, `cli.py` | HTTP application, command line |
| `synthetic.py` | synthetic cluster for the demo mode and the tests |
