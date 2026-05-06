# Architecture

## Goals

The exporter is designed for a single concern: **expose Slurm state as
low-cardinality Prometheus metrics, without becoming a load problem for the
scheduler**. Everything else — auth, packaging, alerting, dashboards — flows
from that.

Hard rules:

* Prometheus scrapes never trigger slurmrestd calls. Polling and serving are
  decoupled. A flapping slurmrestd does not stall `/metrics`.
* No per-jobid, per-pid, or per-hostname-with-FQDN labels. We aggregate.
* No per-node CPU/memory time series with high update rate. Node state is
  poll-driven at 20 s.
* Bounded memory under failure: a stuck collector cannot starve the others;
  retries are bounded; HTTP timeouts are explicit.

## Data flow

```
+-----------------+       JWT (file, refreshed by timer)
|  scontrol token | ---> /run/slurm-monitor/jwt
+-----------------+               |
                                  v
+--------------------+   HTTP   +-----------------+   pull   +------------+
|  slurmrestd        | <------- |  slurm-monitor  | -------> | Prometheus |
|  (Albedo login)    |          |  exporter       |          | (VM)       |
+--------------------+          |  Apptainer/syst |          +------------+
                                |  Tasks: 5       |               |
                                |    nodes  20s   |               | rules
                                |    jobs   30s   |               v
                                |    parts  60s   |          +-------------+
                                |    diag   30s   |          | Alertmgr    |
                                |    res   120s   |          +-------------+
                                +-----------------+               |
                                                                  v
                                                            +-----------+
                                                            |  Grafana  |
                                                            +-----------+
```

## Components

### Exporter (Python, Apptainer)

* **`config.py`** — pydantic-settings, env-prefix `SLURM_MONITOR_`. Optional
  YAML overlay via `SLURM_MONITOR_CONFIG_FILE`.
* **`client/auth.py`** — JWT acquisition: file → command → static, with a
  refresh interval and 401-driven force-refresh.
* **`client/slurmrestd.py`** — async httpx client, version probe via
  `/openapi/v3` falling back to `/slurm/<version>/ping`, retries with
  jittered backoff.
* **`collectors/`** — one collector per slurmrestd resource. Each owns its
  own background task and its own metrics. Failures are isolated.
* **`server/app.py`** — Starlette + uvicorn. Endpoints: `/`, `/metrics`,
  `/healthz`, `/readyz`. `/readyz` returns 503 when any collector has been
  stale for >3× its polling interval (after a configurable startup grace).

### Login-node packaging (Apptainer + systemd)

Three units cooperate:

1. `slurm-monitor-jwt.timer` fires `slurm-monitor-jwt.service` every 10 min,
   running `scontrol token lifespan=900` and writing the JWT into a tmpfs
   `RuntimeDirectory=/run/slurm-monitor` (mode 0750, owner slurm).
2. `slurm-monitor-exporter.service` runs `apptainer run … .sif` with the
   tmpfs bind-mounted read-only at `/run/slurm-monitor`.
3. (optional) `slurm-monitor-tunnel.service` brings up an `autossh` reverse
   tunnel to the monitoring VM in environments where inbound from the VM to
   the login node is blocked. Pull is preferred when available.

### Monitoring VM (Ansible)

The `monitoring_stack` role installs Prometheus + Alertmanager (Ubuntu APT)
and Grafana (official APT repo) on Ubuntu 22.04 / 24.04, then drops:

* `prometheus.yml` rendered from a template (scrape interval, retention,
  external labels)
* `file_sd/slurm.yml` rendered from `monitoring_slurm_targets`
* `rules/recording.yml` + `rules/alerts.yml` shipped verbatim
* `alertmanager.yml` rendered with optional Email + Webex relay receivers
* Grafana provisioning files + four dashboards (overview, nodes, queue,
  scheduler)

## Scaling analysis

**Albedo today (240 nodes):**

| Resource | Calls / minute | Source |
|---|---|---|
| `/slurm/<v>/nodes` | 3 | 20 s interval |
| `/slurm/<v>/jobs` | 2 | 30 s interval |
| `/slurm/<v>/partitions` | 1 | 60 s interval |
| `/slurm/<v>/diag` | 2 | 30 s interval |
| `/slurm/<v>/reservations` | 0.5 | 120 s interval |
| **Total** | **≈ 8.5 RPM** | well under any sane slurmrestd budget |

Cardinality budget at 240 nodes:

| Metric | Series ≈ |
|---|---|
| `slurm_node_*` | 240 nodes × 1–2 partitions × small label set ≈ 500–800 |
| `slurm_jobs{...}` | active users × partitions × QoS × accounts × states. With per-user labels enabled, expect single-thousands during peak. |
| `slurm_partition_*` | partitions × small label set, ≈ 50 |
| `slurm_scheduler_*` | < 20 |

Total active series stays in the tens-of-thousands range at peak, well
within a single-VM Prometheus deployment.

**Scaling levers:**

| Direction | What you change |
|---|---|
| More nodes (300 → 1000) | No exporter change; scrape interval can stay 30 s. Disk grows linearly. |
| More clusters | Run one exporter per cluster; reuse the same `monitoring_slurm_targets` block (each entry already gets a `cluster` label). |
| More fine-grained per-job tracking | Out of scope. Use sacct or a dedicated jobs ETL — do not add per-jobid labels here. |
| GPU device-level metrics | Deploy `dcgm-exporter` on GPU nodes; add a `dcgm` scrape config. Slurm-side allocation metrics already shipped. |

## Operational tradeoffs

* **Polling vs streaming.** Slurm has no eventing. Polling is correct.
  Tighter intervals only help during incidents; the recording rules already
  smooth what dashboards display.
* **Per-user labels.** Enabled today per AWI's choice. If active-user count
  grows past ~500 simultaneously, switch the `JobsCollector` to top-N or
  hashed mode (one parameter, not a redesign).
* **Apptainer vs native venv.** Apptainer adds reproducibility and bind
  isolation at the cost of ~50 MB image and one extra build step. AWI runs
  it everywhere already; we use it.
* **Pull vs autossh fallback.** Pull is the default and the simplest. The
  autossh unit exists for environments where the login-node firewall denies
  inbound — same metrics, no exporter changes.
