# Operations

## Day-2 tasks

### Add or remove a login-node target

Edit `monitoring_slurm_targets` in the Ansible inventory. Re-run:

```bash
cd deploy/ansible
ansible-playbook -i inventory.yml site.yml --tags prometheus
```

Prometheus picks up file_sd changes within 1 minute even without a reload.

### Change the scrape interval / retention

```yaml
# inventory.yml
monitoring_scrape_interval: "20s"
monitoring_retention: "60d"
```

Re-run the playbook; the handler restarts Prometheus.

### Roll the JWT secret

JWT secrets are managed by Slurm itself (`AuthAltParameters=jwt_key=...`).
The exporter only consumes tokens. After Slurm rotates its key, the next
`scontrol token` call returns a token signed by the new key — no exporter
action is required.

### Silence alerts during maintenance

```bash
amtool silence add \
  --duration 4h \
  --comment "Albedo planned downtime 2026-01-15" \
  --alertmanager.url=http://albedo-monitor:9093 \
  cluster=albedo
```

## Backups

Two paths to back up:

| Path | Why |
|---|---|
| `/var/lib/prometheus/metrics2` | TSDB. Snapshots via `curl -X POST http://localhost:9090/api/v1/admin/tsdb/snapshot` (requires `--web.enable-admin-api`). |
| `/var/lib/grafana/grafana.db` | Grafana SQLite (users, snapshots, edits). |

Dashboards are provisioned from git, so do not need backup; the playbook
re-creates them on every run.

## Capacity check

```bash
# Active series on Prometheus
curl -s 'http://localhost:9090/api/v1/status/tsdb' | jq '.data.headStats.numSeries'

# Series count, by metric (run on the VM):
promtool tsdb analyze /var/lib/prometheus/metrics2 | head -30
```

A healthy exporter at 240 nodes runs 30k–50k active series.

## Restart / upgrade order

1. Build a new image: `deploy/apptainer/build.sh dist/...`
2. Roll out to login nodes (`scp` + `systemctl restart slurm-monitor-exporter`).
3. (If the dashboards/rules changed) re-run the Ansible playbook.

The monitoring VM and the login-node exporter can be restarted independently;
neither depends on the other being up.

## Quick diagnostic CLI

```bash
# inside the Apptainer or any venv with the package installed
slurm-monitor check                       # JWT + API version + ping
slurm-monitor dump nodes | jq '.nodes[0]' # raw slurmrestd payload
```

## Known operational quirks

* Slurm 22.x exposes both `cpu_load` (1-min × 100) and node-state on the
  same payload. We divide by 100 for human-readable load.
* If `scontrol token` returns no token (e.g. JWT keys not configured), the
  `slurm-monitor-jwt.service` unit fails. That's correct — investigate
  Slurm rather than the exporter.
* The `up{job="slurm-monitor"}` metric reflects whether **Prometheus** can
  reach the exporter, not whether the exporter can reach slurmrestd. Use
  `slurm_monitor_collector_last_success_timestamp_seconds` for the latter.
