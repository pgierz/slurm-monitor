# Albedo monitoring VM — Ansible

Provisions the **Prometheus + Alertmanager + Grafana** stack on the
monitoring VM. Tested on Ubuntu 22.04 and 24.04 LTS.

## Recommended VM specs

For Albedo (240 nodes, ~30 day retention, 30s scrape):

| Resource | Recommended | Notes |
|---|---|---|
| vCPU | **4** | Prometheus + Grafana fit comfortably; spikes on dashboard load. |
| RAM  | **16 GiB** | Prometheus working set ~6–8 GiB at this cardinality. |
| Disk | **200 GiB SSD** | ~3 GiB/day at this label set; 30d ≈ 90 GiB plus headroom. |
| OS   | Ubuntu 22.04 or 24.04 LTS | Both are tested. |
| Network | inbound: 3000/tcp (Grafana). 9090/tcp + 9093/tcp optional, ops only. Outbound: 9817/tcp to login node(s). |

## Layout

```
deploy/ansible/
├── ansible.cfg                  default flags
├── inventory.example.yml        copy → inventory.yml and edit
├── site.yml                     top-level playbook
└── roles/monitoring_stack/
    ├── defaults/main.yml        all tunables (login-node target, retention, …)
    ├── tasks/                   packages, prometheus, alertmanager, grafana
    ├── handlers/main.yml        service reloads/restarts
    ├── files/                   canonical configs, rules, dashboards
    └── templates/               distro override files (envvars)
```

## Quickstart

```bash
cd deploy/ansible
cp inventory.example.yml inventory.yml
$EDITOR inventory.yml

# Dry-run first
ansible-playbook -i inventory.yml site.yml --check --diff

# Apply
ansible-playbook -i inventory.yml site.yml
```

After the first apply:

* Grafana — http://&lt;vm&gt;:3000 (admin / admin → change password)
* Prometheus — http://&lt;vm&gt;:9090
* Alertmanager — http://&lt;vm&gt;:9093

Edit `roles/monitoring_stack/files/prometheus/file_sd/slurm.yml` when login
nodes are added or removed. The file is tracked in git; re-running the
playbook is the canonical update path.

## Variables you'll likely change

See `roles/monitoring_stack/defaults/main.yml`. The most common:

| Variable | Default | Purpose |
|---|---|---|
| `monitoring_retention` | `30d` | Prometheus TSDB retention |
| `monitoring_scrape_interval` | `30s` | Global scrape interval |
| `monitoring_grafana_admin_password` | `admin` | Set this in your inventory or via a vault |
| `monitoring_alertmanager_smtp_*` | unset | Email alerting |
