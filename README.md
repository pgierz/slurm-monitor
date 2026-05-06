# slurm-monitor

[![Documentation Status](https://readthedocs.org/projects/slurm-monitor/badge/?version=latest)](https://slurm-monitor.readthedocs.io/en/latest/?badge=latest)

A Prometheus exporter for Slurm + a turnkey Grafana stack, built for AWI's
Albedo cluster (240 nodes, A100 / A40 GPUs).

## What you get

| Piece | Where |
|---|---|
| Async Python exporter that talks to **slurmrestd** over JWT | `src/slurm_monitor/` |
| **Apptainer** image + **systemd** units for the login node | `deploy/apptainer/`, `deploy/systemd/` |
| **Ansible** role for the monitoring VM (Prom + Alertmanager + Grafana) | `deploy/ansible/` |
| Recording rules, alert rules, dashboards | `deploy/ansible/roles/monitoring_stack/files/` |
| Architecture, install, ops, troubleshooting docs | `docs/` |

## Architecture in one paragraph

A small Python service runs in an Apptainer container on an Albedo login node.
A systemd timer refreshes a Slurm JWT into a tmpfs file every 10 minutes; the
exporter reads it, polls **slurmrestd** on five independent intervals
(20–120 s) for nodes / jobs / partitions / diagnostics / reservations, and
writes the result into a Prometheus registry. A separate Ubuntu **monitoring
VM** runs Prometheus, Alertmanager, and Grafana — provisioned by the Ansible
role in `deploy/ansible/` — and pulls `/metrics` from the login node every
30 s. Prometheus scrapes never reach Slurm, so the dashboards stay up even
when slurmrestd flaps.

## Quickstart

### Login node (exporter)

```bash
deploy/apptainer/build.sh                    # builds dist/slurm-monitor-exporter.sif
sudo install -d /opt/slurm-monitor
sudo install -m0644 dist/slurm-monitor-exporter.sif /opt/slurm-monitor/

sudo install -d /etc/slurm-monitor
sudo install -m0640 deploy/systemd/exporter.env.example /etc/slurm-monitor/exporter.env
sudo $EDITOR /etc/slurm-monitor/exporter.env

sudo install -m0644 deploy/systemd/slurm-monitor-jwt.service /etc/systemd/system/
sudo install -m0644 deploy/systemd/slurm-monitor-jwt.timer   /etc/systemd/system/
sudo install -m0644 deploy/systemd/slurm-monitor-exporter.service /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now slurm-monitor-jwt.timer
sudo systemctl enable --now slurm-monitor-exporter.service
curl -s http://localhost:9817/healthz
```

### Monitoring VM

```bash
cd deploy/ansible
cp inventory.example.yml inventory.yml
$EDITOR inventory.yml          # set FQDN + login-node targets + Grafana password
ansible-playbook -i inventory.yml site.yml --check --diff
ansible-playbook -i inventory.yml site.yml
```

Then visit `http://<vm>:3000` (admin / your password).

## Documentation

* [Architecture](docs/architecture/overview.md)
* [Installation guide](docs/operations/install.md)
* [Operations guide](docs/operations/ops.md)
* [Troubleshooting](docs/operations/troubleshooting.md)
* [Upgrade strategy](docs/operations/upgrade.md)
* [Metrics reference](docs/architecture/metrics.md)

## Development

```bash
pixi install --environment dev
pixi run --environment dev test
pixi run exporter            # localhost:9817 — pointed at $SLURM_MONITOR_SLURM_BASE_URL
pixi run slurm-monitor check # one-shot probe: JWT + API version + ping
```
