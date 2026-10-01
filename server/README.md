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
at the top of that file). `deploy/slurm-monitor-server.service` is a systemd
unit for the virtual-environment install.

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
api_version = "v0.0.40"          # what your slurmrestd offers: see `slurmrestd -d list`
user_name = "slurm-monitor"
token_file = "/run/slurm-monitor/slurm.jwt"

[auth.static]
enabled = true                   # tokens from the environment
```

### What the Slurm user must be able to see

The server reads `/slurm/{v}/jobs`, `/slurm/{v}/nodes`, `/slurm/{v}/partitions`,
`/slurmdb/{v}/qos` and `/slurm/{v}/shares`. With `PrivateData` set in
`slurm.conf`, an ordinary user sees only its own jobs and shares; the Slurm
user of this server then needs operator rights (or to be the `SlurmUser`) for
the cluster-wide figures to be right.

Jobs and nodes are required: when either fails, the poll fails, and the server
keeps answering from the last good poll with `"stale": true`. Partitions, QOS
and shares are optional: without QOS the limits are `null`, without shares
(older than v0.0.40, or no slurmdbd) `fairshare` is `null`.

### Token rotation

Slurm JWTs expire. Three ways to supply one, in order of preference:

1. **A token file, rotated by cron or a systemd timer.** The file is read anew
   on every poll, so nothing needs restarting:

   ```sh
   # /etc/cron.d/slurm-monitor-token (runs as root or SlurmUser)
   */30 * * * * root  umask 077; scontrol token username=slurm-monitor lifespan=7200 \
       | sed 's/^SLURM_JWT=//' > /run/slurm-monitor/slurm.jwt.new \
       && chown slurm-monitor: /run/slurm-monitor/slurm.jwt.new \
       && mv /run/slurm-monitor/slurm.jwt.new /run/slurm-monitor/slurm.jwt
   ```

   The lifespan is longer than the rotation interval, so a missed run does no
   harm. The `SLURM_JWT=` prefix may also be left in; the server strips it.

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
  Helmholtz AAI. JWT access tokens are validated against the issuer's JWKS
  (signature, issuer, expiry, and the audience when `audience` is set). Opaque
  tokens, and JWTs that lack the needed claims, are resolved through the
  issuer's userinfo endpoint and cached for `userinfo_cache_seconds`. With
  `required_entitlements`, an identity lacking all of them gets 403. The
  Slurm user name comes from `username_claim` (default `preferred_username`),
  or from `username_map` where that claim differs from the cluster account.
  With OIDC, `user` defaults to that name. `user=*` asks for no particular user
  (the whole cluster's view), with either method.

  When the issuer cannot be reached, the answer is `503
  {"error": "auth_unavailable"}` rather than 401, so that the app does not
  ask the person to sign in again because of an outage.

If no method is enabled, every request to a protected endpoint gets 401.
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
poll the family endpoints answer `503 {"error": "no_data"}`.

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
