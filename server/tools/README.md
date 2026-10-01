# Tools for the real cluster

Two single-file scripts, standard library only, Python 3.6 or newer. Copy them
to the cluster; nothing needs installing.

| File | Runs on | Purpose |
|---|---|---|
| `dump_slurmrestd.py` | a login node | records the slurmrestd payloads the server consumes |
| `gpu_collector.py` | each GPU node without a DCGM exporter | serves nvidia-smi figures as JSON |
| `gpu-collector.service` | each such GPU node | systemd unit for the collector |

## dump_slurmrestd.py

The server is developed against synthetic data. This script records what the
real slurmrestd answers, so the fixtures can be checked against it.

```sh
# token: taken from $SLURM_JWT, otherwise from `scontrol token`
python3 dump_slurmrestd.py --base-url https://slurm.example.org:6820 \
    --output-dir slurmrestd-dump
```

| Option | Meaning |
|---|---|
| `--base-url URL` | slurmrestd base URL (or `$SLURMRESTD_URL`) |
| `--api-version v0.0.41` | fixed version; otherwise the newest one in the OpenAPI document, separately for `slurm` and `slurmdb` |
| `--user NAME` | Slurm user the token belongs to (default: the current user) |
| `--output-dir DIR` | default `slurmrestd-dump` |
| `--anonymise` / `--no-anonymise` | anonymisation is on by default |
| `--keep-user NAME` | leave this user name as it is (repeatable), e.g. your own, to test the "mine" views |
| `--runner-pattern REGEX` | job name prefixes to keep (repeatable, replaces the defaults `^ci-\d+`, `^dask-gateway`, `^(spawner-)?jupyterhub`) |
| `--keep-word WORD` | words kept in anonymised job names and commands (defaults `scheduler`, `worker`) |
| `--salt TEXT` | fixed salt for the hashes; by default a random one per run |
| `--ca-file FILE`, `--timeout S` | HTTPS CA bundle, request timeout |

Exit status: 0 when everything was recorded, 1 when an endpoint failed (the
others are still written), 2 when no token or no API version was found.
`/slurm/{v}/shares` only exists from v0.0.40 on; with older versions it is
reported as missing.

### What the dump contains

| File | Source |
|---|---|
| `jobs.json` | `/slurm/{v}/jobs` |
| `nodes.json` | `/slurm/{v}/nodes` |
| `partitions.json` | `/slurm/{v}/partitions` |
| `qos.json` | `/slurmdb/{v}/qos` |
| `shares.json` | `/slurm/{v}/shares` |
| `openapi.json` | `/openapi/v3`, else `/openapi.json`, else `/openapi` (schema only, written unchanged) |
| `manifest.json` | time, API versions, per-endpoint result, file sizes; neither the base URL nor the token |

### What is replaced, what is kept

Replaced with stable pseudonyms, the same one in every file of a run:

| Data | Becomes |
|---|---|
| user names (`user_name`, `association.user`, shares rows of type USER, `meta.client.user`, …) | `user001` |
| account names (also in partition allow/deny lists and shares parents) | `acct01` |
| Unix group names | `group01` |
| job names | `job000123`; names matching a runner pattern keep the matched prefix, the rest becomes a hash: `ci-12345` stays, `dask-gateway-<name>-scheduler` → `dask-gateway-scheduler-3fa9c1` |
| comments | `c-<hash>`; empty stays empty, equal comments stay equal (Dask clusters still group) |
| working directory, standard input/output/error, container | `/scrubbed/path-<hash>` |
| command, submit line, script | `/scrubbed/command-<hash>`, plus `-scheduler`/`-worker` if the word occurred |
| e-mail addresses, anywhere | `user001@example.org` or `mail-<hash>@example.org` |
| `wckey`, `extra`, `mcs_label`, burst buffer, environment | `x-<hash>` |
| `meta.client.source` (host and port of the caller) | `scrubbed` |
| any other string | scrubbed if it starts with or contains a path; known user names and e-mail addresses inside it are replaced |

Kept: node names, partition names, QOS names and descriptions, GRES and TRES
strings, states, reasons, features, the cluster name, and **all numbers**.
Numbers include job ids, time stamps and the numeric `user_id`/`group_id`.
If numeric ids are considered personal data at your site, remove them before
sharing, e.g. `jq 'del(.jobs[].user_id, .jobs[].group_id)' jobs.json`.

`root` is never renamed. Both slurmrestd JSON styles are handled (plain values
and `{"set": true, "infinite": false, "number": N}` objects).

### Checking before sharing

The script checks its own output and prints either "Self-check: no known user,
account or group name … left" or a `REVIEW BEFORE SHARING` list of key paths.
A listed hit is not always a leak: an account that has the same name as a
partition is reported because partition names are kept on purpose.

Then look yourself, on the login node:

```sh
cd slurmrestd-dump
# your own and a few colleagues' user names, your account, your home prefix
grep -n -w -e "$USER" -e "$(id -gn)" *.json
grep -n -E '/home/|/work/|/scratch/' jobs.json nodes.json   # adapt the prefixes
grep -n -o -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' *.json | grep -v '@example.org'
# every distinct job name, user and account that is left
python3 -c 'import json;j=json.load(open("jobs.json"))["jobs"];print(sorted({x["name"] for x in j}));print(sorted({x.get("user_name") for x in j}), sorted({x.get("account") for x in j}))'
```

All four should show nothing personal. Node reasons are free text written by
administrators; read them once (`grep -n '"reason"' nodes.json`).

## gpu_collector.py

```sh
python3 gpu_collector.py --port 9455 --interval 5
curl http://localhost:9455/metrics.json
```

```json
{"node": "gpu-005", "cards": [{"index": 0, "utilisation": 0.97,
 "memory_used_mib": 36864, "memory_total_mib": 40960, "temperature_c": 74,
 "power_w": 286}]}
```

- `node` is the short host name (override with `--node`).
- `utilisation` is a fraction 0…1; a value nvidia-smi reports as `[N/A]` is `null`.
- nvidia-smi runs at most once per `--interval` seconds, however many requests arrive.
- nvidia-smi missing, failing or hanging (`--timeout`, default 10 s):
  HTTP 503 `{"error": "nvidia_smi_unavailable", "detail": "…"}`.
- Other options: `--bind ADDRESS` (default all interfaces), `--nvidia-smi PATH`.

The collector has no authentication and reveals nothing but the figures above;
still, restrict the port to the host of the middle server with the node
firewall.

Install as a service:

```sh
install -D -m 0755 gpu_collector.py /usr/local/libexec/slurm-monitor/gpu_collector.py
install -m 0644 gpu-collector.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now gpu-collector
```

## Tests

```sh
python3 -m pytest server/tools/tests
```
