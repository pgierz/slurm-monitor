# Upgrade strategy

## Versioning

Releases follow [SemVer](https://semver.org). The repository ships a
[`semantic-release`](https://python-semantic-release.readthedocs.io)
configuration that bumps `pyproject.toml` and tags from conventional commit
messages on `main` / `master`.

| Change | Bump |
|---|---|
| Adds a new metric or label | minor |
| Renames or drops an existing metric | major |
| Bug fix that does not change metric names or labels | patch |
| Adds a dashboard panel or new alert rule | minor |
| Adjusts an alert threshold | patch |

## Upgrading the exporter (login node)

```bash
git pull
deploy/apptainer/build.sh dist/slurm-monitor-exporter.sif
sudo install -m0644 dist/slurm-monitor-exporter.sif /opt/slurm-monitor/
sudo systemctl restart slurm-monitor-exporter
sudo journalctl -u slurm-monitor-exporter -n 50 --no-pager
```

The unit is `Restart=on-failure`, so a misbehaving start aborts cleanly.

## Upgrading the monitoring VM

The Ansible playbook is idempotent. To upgrade Prometheus / Alertmanager
(distro APT) and Grafana (Grafana APT) plus pull the latest configs and
dashboards:

```bash
cd deploy/ansible
git pull
ansible-playbook -i inventory.yml site.yml
```

To pin Grafana to a specific minor release, use the standard APT pinning
mechanism on the VM (the role does not pin by default, intentionally).

## Slurm 22.x → 23.x → 24.x

The exporter probes `/openapi/v3` at start and picks the highest supported
OpenAPI version among `v0.0.40`, `v0.0.39`, `v0.0.38`, `v0.0.37`. New Slurm
versions usually keep the older API plugin around for at least one major
release, so you can upgrade Slurm before upgrading the exporter, then
upgrade the exporter at your leisure.

If a future Slurm drops a version we depend on, add it to
`SUPPORTED_VERSIONS` in `src/slurm_monitor/client/slurmrestd.py` and write
the small adapter in `collectors/_helpers.py` if any field shape changed.

## Rollback

* **Exporter** — keep the previous SIF: `sudo cp /opt/slurm-monitor/slurm-monitor-exporter.sif{,.prev}` before each update; on regression `mv .prev` back and restart.
* **Stack** — `git checkout` an earlier tag and rerun the playbook. Configs
  are the source of truth; the role overwrites them on every run.
* **Dashboards** — same as configs; provisioning replaces the JSON on every
  Grafana restart, so a `git revert` + playbook rerun is sufficient.

## Testing changes locally

```bash
pixi install --environment dev
pixi run --environment dev test
pixi run --environment dev exporter   # with SLURM_MONITOR_AUTH_TOKEN=... pointed at a sandbox
```

The `respx` test layer covers the slurmrestd schema-drift cases that have
historically been the source of bugs across Slurm minor versions.
