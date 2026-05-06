# Troubleshooting

## Symptom matrix

| Symptom | Most likely cause | Where to look |
|---|---|---|
| `up{job="slurm-monitor"} == 0` | Network / firewall, exporter crashed, port wrong | `journalctl -u slurm-monitor-exporter` on the login node |
| `/healthz` 200 but `/readyz` 503 | A collector hasn't completed yet, or slurmrestd is slow/down | check `slurm_monitor_collector_last_success_timestamp_seconds` |
| `SlurmCollectorErrorBurst` firing | slurmrestd flapping or auth broken | exporter logs; `scontrol token` by hand |
| Empty Grafana panels | Datasource UID mismatch or wrong cluster filter | datasource UID is `albedo-prom` |
| Alertmanager UI shows 0 receivers | Default null receiver — expected until you wire one up | `monitoring_alertmanager_email_*` or `monitoring_alertmanager_webex_relay_url` |

## Reading exporter logs

The exporter emits structured JSON by default. Pipe through `jq`:

```bash
journalctl -u slurm-monitor-exporter -o cat | jq -r 'select(.level == "warning") | "\(.timestamp) \(.event)"'
```

Useful events:

* `slurmrestd.api_version.detected` — version probe succeeded
* `slurmrestd.api_version.fallback` — `/openapi/v3` failed; we picked a
  version by probing `ping` endpoints
* `slurmrestd.auth.refresh_on_401` — a token expired between scheduled
  refreshes; we recovered automatically
* `collector.error` — a single collection attempt failed; the value of
  `status` (`http <code>`) explains why

## "scontrol token" is empty / fails

Slurm must be configured with JWT auth:

```ini
# /etc/slurm/slurm.conf
AuthAltTypes=auth/jwt
AuthAltParameters=jwt_key=/var/spool/slurmctld/jwt_hs256.key
```

The `jwt_key` file must exist on slurmctld and on the login node.

To prove auth out without the exporter:

```bash
sudo -u slurm scontrol token lifespan=900 | tee /tmp/jwt
TOK=$(awk -F= '{print $2}' /tmp/jwt)
curl -sS -H "X-SLURM-USER-NAME: slurm" -H "X-SLURM-USER-TOKEN: $TOK" \
  http://127.0.0.1:6820/openapi/v3 | jq '.paths | keys[]' | head
```

If that works but the exporter doesn't, capture exporter env:

```bash
sudo systemctl show slurm-monitor-exporter --property=Environment
```

## OpenAPI version probe failed

If the logs say `slurmrestd.openapi.probe_failed`, slurmrestd may be running
without the openapi/v3 plugin enabled. Enable in
`/etc/slurm/slurmrestd.conf`:

```
include /etc/slurm/plugstack.conf

# Enable specific OpenAPI versions
SlurmrestdPlugins=openapi/v0.0.39,openapi/v0.0.38,openapi/v0.0.37,openapi/v3
```

Restart slurmrestd, then `slurm-monitor check` from the login node.

## Prometheus rule errors after upgrade

```bash
sudo promtool check rules /etc/prometheus/rules/*.yml
```

If the recording or alert files fail validation, revert to the previous
version under `/etc/prometheus/rules/.bak` (the playbook does not back up,
but `etckeeper` or git on `/etc/prometheus/rules/` is recommended).

## High cardinality

If Prometheus disk usage explodes, check the user count:

```promql
count(count by (user) (slurm_jobs))
```

If it climbs past several hundred routinely, switch the JobsCollector to
top-N (planned). For now you can drop the user label entirely with a
`metric_relabel_configs` block:

```yaml
- source_labels: [__name__]
  regex: 'slurm_jobs.*'
  action: labeldrop
  regex: 'user'
```

## Exporter pegged at 100% CPU

Almost always a collector loop with a slow slurmrestd response and the next
poll interval already firing. Bump intervals:

```ini
SLURM_MONITOR_INTERVAL_NODES_SECONDS=60
SLURM_MONITOR_INTERVAL_JOBS_SECONDS=60
```

…and investigate slurmctld load separately.
