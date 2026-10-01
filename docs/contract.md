# Data contract between the middle server and the app

Schema version: **1**. This document is the single source of truth. The server
must emit exactly these shapes; the Swift models must decode exactly these
shapes. Unknown fields must be ignored by the client. A change of meaning or a
removed field requires a new `schema_version`.

## Transport

- Base path: `/api/v1`
- Authentication: `Authorization: Bearer <token>`. The token is either the
  static token from the server configuration or a Helmholtz AAI (OIDC) access
  token. The server accepts whichever methods are enabled.
- All timestamps are ISO 8601 in UTC with a `Z` suffix and whole seconds
  (`2026-10-01T12:32:07Z`). All durations are integer seconds.
- All field names are `snake_case`. `null` means "not known / not applicable".
- Errors: `401 {"error": "unauthorized"}`, `403 {"error": "forbidden"}`,
  `503 {"error": "no_data"}` (the server has not yet completed a first poll).

### What the client makes of failures

| Situation | Widget state |
|---|---|
| 200, `stale` false | live |
| 200, `stale` true, or a cached snapshot older than 10 minutes | stale (dimmed, "as of HH:MM") |
| Connection failure, timeout, DNS failure, 5xx | "VPN needed", with the last cached snapshot's key figures if any |
| 401 or 403, or no credentials stored | "Sign in needed" |

## Endpoints

| Method and path | Auth | Query parameters | `data` shape |
|---|---|---|---|
| `GET /api/v1/health` | none | – | not enveloped, see below |
| `GET /api/v1/auth/config` | none | – | not enveloped, see below |
| `GET /api/v1/me` | yes | – | not enveloped, see below |
| `GET /api/v1/queue` | yes | `partition`, `user`, `qos` (all optional) | Queue |
| `GET /api/v1/nodes` | yes | `partition` (optional) | Nodes |
| `GET /api/v1/qos` | yes | `user` (optional) | Qos |
| `GET /api/v1/gpu` | yes | – | Gpu |
| `GET /api/v1/runners` | yes | `user` (optional) | Runners |

`user` selects whose jobs count as "mine". With an AAI token the server
defaults it to the mapped Slurm username; with the static token the client
sends the username from its settings.

### Envelope

Every family endpoint returns:

```json
{
  "schema_version": 1,
  "cluster": "albedo",
  "generated_at": "2026-10-01T12:32:07Z",
  "stale": false,
  "data": { }
}
```

`generated_at` is the time of the slurmrestd poll the snapshot is built from.
`stale` is true when the most recent poll failed and the server is answering
from an older one.

### `GET /api/v1/health`

```json
{"status": "ok", "version": "1.0.0", "schema_version": 1,
 "last_poll_at": "2026-10-01T12:32:07Z", "last_poll_ok": true}
```

### `GET /api/v1/auth/config`

```json
{"methods": ["token", "oidc"],
 "oidc": {"issuer": "https://login.helmholtz.de/oauth2",
          "client_id": "slurm-monitor-app",
          "scopes": ["openid", "profile", "email", "eduperson_entitlement"]}}
```

`oidc` is `null` when OIDC is not enabled. The app uses the authorization code
flow with PKCE, a public client (no secret) and the redirect URI
`de.awi.slurm-monitor:/oauth/callback`.

### `GET /api/v1/me`

```json
{"method": "oidc", "subject": "…", "username": "pgierz"}
```

`username` is the Slurm username, or `null` when it cannot be derived (static
token).

## Queue

```json
{
  "partition": null,
  "qos": null,
  "user": "pgierz",
  "running": 412,
  "pending": 96,
  "mine": {"running": 12, "pending": 3},
  "pending_by_reason": [
    {"reason": "Priority", "count": 58},
    {"reason": "Resources", "count": 27},
    {"reason": "QOS limit", "count": 8},
    {"reason": "Dependency", "count": 3}
  ],
  "my_jobs_total": 15,
  "my_jobs": [
    {"job_id": 4711001, "name": "awiesm_lig125k", "state": "R",
     "partition": "mpp", "resources": "16 nodes",
     "elapsed_seconds": 18720, "time_limit_seconds": 43200,
     "estimated_start": null, "reason": null},
    {"job_id": 4711007, "name": "awiesm_lig127k", "state": "PD",
     "partition": "mpp", "resources": "16 nodes",
     "elapsed_seconds": 0, "time_limit_seconds": 43200,
     "estimated_start": "2026-10-01T13:40:00Z", "reason": "Priority"}
  ],
  "history": [
    {"t": "2026-10-01T12:00:00Z", "running": 405, "pending": 91}
  ]
}
```

- `mine` is `null` when no user is known. `my_jobs` is then empty.
- `state` is `"R"` or `"PD"` only; other job states are not listed.
- `pending_by_reason` is sorted by count, descending. Reasons are normalised
  to: `Priority`, `Resources`, `QOS limit` (any `QOS*` or `Assoc*` limit
  reason), `Dependency`, `Held` (`JobHeldUser`, `JobHeldAdmin`), `Other`.
  At most 6 entries; zero-count reasons are omitted.
- `my_jobs`: running first (longest elapsed first), then pending (earliest
  estimated start first, unknown last). At most 20 entries;
  `my_jobs_total` is the full count.
- `resources`: a short human string, `"16 nodes"`, `"64 cores"` or
  `"2 A100"` for GPU jobs.
- `time_limit_seconds` is `null` for unlimited.
- `history`: at most 72 points, one per 5 minutes, oldest first.

## Nodes

```json
{
  "total": 240, "allocated": 198, "idle": 26, "drained": 11, "down": 5,
  "partitions": [
    {"name": "mpp", "total": 170, "allocated": 148, "idle": 14,
     "drained": 6, "down": 2,
     "nodes": [{"name": "prod-001", "state": "allocated"}]}
  ]
}
```

- Node `state` is one of `allocated`, `idle`, `drained`, `down`.
  Mapping from Slurm: `DOWN`, `FAIL`, `NOT_RESPONDING`, `POWERED_DOWN`,
  `UNKNOWN` → `down` (checked first); `DRAIN`, `DRAINING`, `DRAINED`, `MAINT`,
  `RESERVED` → `drained`; `ALLOCATED`, `MIXED`, `COMPLETING` → `allocated`;
  otherwise `idle`.
- Top-level counts are over unique nodes. A node in two partitions appears in
  both partition entries.
- Partitions are sorted by node count, descending. Nodes are sorted by name.
- With the `partition` query parameter, only that partition is returned and
  the top-level counts refer to it.

## Qos

```json
{
  "user": "pgierz",
  "account": "hpc",
  "fairshare": 0.42,
  "qos": [
    {"name": "12h", "cpus_in_use": 14200, "cpu_limit": 18000,
     "running_jobs": 310, "pending_jobs": 61, "max_wall_seconds": 43200}
  ]
}
```

- `account` and `fairshare` are `null` when no user is known or slurmdb does
  not report them. `fairshare` is the normalised fairshare factor, 0…1.
- `cpu_limit` is the QOS group CPU limit (`GrpTRES cpu`), `null` when unset.
- Only QOS with at least one job or a set limit are listed, sorted by
  `cpus_in_use`, descending.

## Gpu

```json
{
  "metrics_available": true,
  "total": 24, "allocated": 14, "idle_allocated": 3,
  "pending_jobs": 6, "longest_wait_seconds": 11520,
  "types": [
    {"type": "a100", "label": "A100", "total": 16, "allocated": 11},
    {"type": "a40", "label": "A40", "total": 8, "allocated": 3}
  ],
  "nodes": [
    {"name": "gpu-005", "type": "a100", "state": "allocated",
     "cards": [
       {"index": 0, "state": "busy", "utilisation": 0.97,
        "memory_used_mib": 36864, "memory_total_mib": 40960,
        "temperature_c": 74, "power_w": 286, "user": "pgierz"}
     ]}
  ],
  "top_users": [{"user": "pgierz", "cards": 4}],
  "history": [
    {"t": "2026-10-01T12:00:00Z", "allocated_fraction": 0.58,
     "utilisation": 0.71}
  ]
}
```

- Card `state`: `busy` (allocated, utilisation ≥ 5 %), `idle_allocated`
  (allocated, utilisation < 5 %), `allocated` (allocated, no metrics
  available), `free`, `drained`, `down`. A card inherits `drained`/`down`
  from its node unless it is allocated.
- When `metrics_available` is false: `idle_allocated` is `null`, cards are
  never `busy` or `idle_allocated`, all metric fields are `null`, and
  `history[].utilisation` is `null`.
- `type` is the lower-case GRES type; `label` its display name.
- Nodes are sorted by type (largest total first), then by name.
- `top_users`: at most 5, sorted by cards, descending.
- `history`: at most 72 points, one per 5 minutes, oldest first.
  `utilisation` is the mean over allocated cards.

## Runners

```json
{
  "ci": {"runners_alive": 4, "jobs_waiting": 7, "oldest_wait_seconds": 1080},
  "dask": {"clusters": [
    {"id": "a3f1", "owner": "pgierz", "scheduler_alive": true,
     "workers_running": 14, "workers_requested": 16,
     "walltime_left_seconds": 2520}
  ]},
  "jupyterhub": {"sessions": 23, "with_gpu": 4, "near_walltime": 2},
  "extra": [
    {"key": "matlab", "label": "MATLAB", "running": 3, "pending": 0}
  ]
}
```

- Jobs are classified by regular expressions on the job name, set in the
  server configuration. Defaults: CI `^ci-\d+`, Dask `^dask-gateway`,
  JupyterHub `^(spawner-)?jupyterhub`.
- CI: `runners_alive` counts running CI jobs, `jobs_waiting` pending ones,
  `oldest_wait_seconds` is `null` when none wait.
- Dask: jobs are grouped into clusters by a configurable field (default: the
  job `comment`, falling back to owner). The scheduler is recognised by a
  second pattern on the job name or command (default `scheduler`).
  `walltime_left_seconds` is the minimum over the running workers, `null`
  when none run. With the `user` parameter only that user's clusters are
  listed. Sorted by owner, then id. At most 10 clusters.
- JupyterHub: `near_walltime` counts sessions with less than 15 minutes left.
- `extra`: further name-pattern kinds from the configuration; may be empty.
