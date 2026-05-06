# Installation

This guide installs the exporter on a single Albedo login/utility node and
the monitoring stack on a dedicated VM.

## 0. Prerequisites

* slurmrestd is reachable from the login node (the local default
  `http://127.0.0.1:6820` is fine).
* Slurm is configured with JWT auth (`AuthAltTypes=auth/jwt` in
  `slurm.conf`).
* The login node can run `scontrol token` as the `slurm` user (it must be
  inside the Munge trust domain).
* Apptainer ≥ 1.2 is installed on the login node.
* The monitoring VM is Ubuntu 22.04 or 24.04 with sudo access.

## 1. Build the Apptainer image

On any host with Apptainer + a Python toolchain:

```bash
git clone https://github.com/pgierz/slurm-monitor.git
cd slurm-monitor
deploy/apptainer/build.sh dist/slurm-monitor-exporter.sif
```

Copy the SIF to `/opt/slurm-monitor/` on each Albedo login node:

```bash
sudo install -d /opt/slurm-monitor
sudo install -m0644 dist/slurm-monitor-exporter.sif /opt/slurm-monitor/
```

## 2. Install systemd units on the login node

```bash
sudo install -d -m0750 /etc/slurm-monitor
sudo useradd --system --no-create-home --shell /usr/sbin/nologin slurm-monitor || true
sudo install -m0640 -o root -g slurm-monitor \
  deploy/systemd/exporter.env.example /etc/slurm-monitor/exporter.env
sudo $EDITOR /etc/slurm-monitor/exporter.env

sudo install -m0644 deploy/systemd/slurm-monitor-jwt.service /etc/systemd/system/
sudo install -m0644 deploy/systemd/slurm-monitor-jwt.timer /etc/systemd/system/
sudo install -m0644 deploy/systemd/slurm-monitor-exporter.service /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now slurm-monitor-jwt.timer
sudo systemctl enable --now slurm-monitor-exporter.service
```

Verify:

```bash
sudo systemctl status slurm-monitor-jwt.timer slurm-monitor-exporter.service
sudo -u slurm-monitor curl -s http://127.0.0.1:9817/healthz
sudo -u slurm-monitor curl -s http://127.0.0.1:9817/metrics | head
```

## 3. Provision the monitoring VM

From any control machine that has Ansible ≥ 2.14:

```bash
cd deploy/ansible
cp inventory.example.yml inventory.yml
$EDITOR inventory.yml          # set FQDN, login-node targets, Grafana password

ansible-playbook -i inventory.yml site.yml --check --diff
ansible-playbook -i inventory.yml site.yml
```

Verify on the VM:

```bash
systemctl status prometheus prometheus-alertmanager grafana-server
curl -s http://localhost:9090/-/ready
curl -s http://localhost:9093/-/ready
```

Open Grafana at `http://<vm>:3000`.

## 4. Reverse SSH tunnel (optional fallback)

If the VM cannot reach login-node port 9817, install the autossh unit on
each login node:

```bash
sudo apt-get install -y autossh
sudo install -m0644 deploy/systemd/slurm-monitor-tunnel.service /etc/systemd/system/
sudo install -m0640 deploy/systemd/tunnel.env.example /etc/slurm-monitor/tunnel.env
sudo $EDITOR /etc/slurm-monitor/tunnel.env

sudo systemctl daemon-reload
sudo systemctl enable --now slurm-monitor-tunnel.service
```

Then update `monitoring_slurm_targets` in the inventory to point at
`127.0.0.1:<REMOTE_PORT>` on the VM.

## 5. Hardening

* Set the Grafana admin password via `monitoring_grafana_admin_password`
  (use Ansible Vault).
* Restrict Prometheus and Alertmanager listeners to `127.0.0.1` if you
  expose Grafana via reverse proxy only.
* Move slurmrestd to HTTPS and set `SLURM_MONITOR_SLURM_BASE_URL=https://...`
  with `SLURM_MONITOR_SLURM_CA_BUNDLE=/etc/slurm-monitor/ca.pem`.
