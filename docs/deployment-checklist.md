# First deployment on the real cluster

In order. Examples use `slurm.example.org`; real names go into configuration,
not into the repository.

1. **Service user and token**
   - [ ] A service user exists in Slurm that may read all jobs
         (operator level, or `PrivateData` not hiding other users' jobs).
   - [ ] slurmrestd is reachable from the server host and JWT authentication
         is enabled (`AuthAltTypes=auth/jwt`).
   - [ ] Token issued by an administrator:
         `scontrol token username=<service user> lifespan=<seconds>`.
   - [ ] Rotation in place: a timer issues a new token before the old one
         expires and writes it, mode 0600, where the server reads it. Decide
         the lifespan (days, not years) and who is told when rotation fails.

2. **Record real payloads**
   - [ ] `python3 server/tools/dump_slurmrestd.py --base-url https://slurm.example.org:6820`
   - [ ] Check the anonymisation (`server/tools/README.md`, "Checking before sharing").
   - [ ] Note the API versions the script detected (first line of its
         output, `api_versions` in `manifest.json`). The server detects the
         newest version in the same way when `slurm.api_version` is not set;
         fix the version in the configuration only if the newest one
         misbehaves.
   - [ ] Compare with the synthetic fixtures in `server/tests`: API version,
         JSON style (plain values or `set/infinite/number` objects), field
         names the server reads, state and reason strings, GRES format.
   - [ ] Note whether `shares.json` was written (needs v0.0.40 or newer).
   - [ ] Run the server tests against the dump; correct server or fixtures.

3. **GPU metrics source**
   - [ ] DCGM exporter and Prometheus already there → use them; note the
         Prometheus URL and the label that carries the node name.
   - [ ] Otherwise install `gpu_collector.py` with `gpu-collector.service` on
         every GPU node; open port 9455 to the server host only;
         `curl http://<node>:9455/metrics.json` from the server host.
   - [ ] The collector is reached by Slurm node name
         (`http://<NodeName>:9455/metrics.json`). Where `NodeAddr` or
         `NodeHostname` differ from `NodeName` in `slurm.conf`
         (`scontrol show node <node> | grep -E 'NodeAddr|NodeHostName'`),
         check that the node name itself resolves from the server host, and
         that it leads to the interface the collector listens on. With
         Prometheus, check that the node label holds the Slurm node name
         (a domain and a port are stripped, nothing else).
   - [ ] The card indices of the metrics source match Slurm's `IDX`
         numbering. On a GPU node with a running GPU job compare
         `scontrol show node <node> | grep GresUsed` (or
         `scontrol show job -d <jobid> | grep IDX`) with
         `nvidia-smi --query-gpu=index,uuid,utilization.gpu --format=csv`
         and, for DCGM, the `gpu` label: the card Slurm calls `IDX:0` must be
         the one the source calls index 0, and the busy card must be the
         allocated one. They differ when `gres.conf` lists the device files
         in another order than the driver enumerates them; correct
         `gres.conf` (or use `AutoDetect=nvml`), since a wrong pairing shows
         busy cards as idle.
   - [ ] Neither → run with `metrics_available: false` for now.

4. **Helmholtz AAI client** (`docs/helmholtz-aai.md`)
   - [ ] Trial client on `login-dev.helmholtz.de`; settle the "Not verified" list.
   - [ ] Production client requested and approved; client id noted.
   - [ ] Entitlement URN for access and the username claim decided.

5. **Install the server** (`server/README.md`)
   - [ ] Configuration: slurmrestd URL, service user, token file, cluster
         name, GPU source, OIDC issuer and client id, static token if used.
   - [ ] Token rotation: `slurm-monitor-token.timer` enabled
         (`server/deploy`), token file readable by the server's user (in a
         container: by the container's uid).
   - [ ] Service running; `GET /api/v1/health` shows `last_poll_ok: true`
         and, in `slurm_api_version`, the version that was detected (also in
         the log at start-up).
   - [ ] Reachable from the VPN, and only from there.

6. **Confirm the job name patterns against the live queue**
   - [ ] CI (Jacamar), default `^ci-\d+`:
         `squeue -h -o '%j %u' | grep -E '^ci-[0-9]+' | head`
   - [ ] Dask gateway, default `^dask-gateway`; also check that the comment
         holds the cluster id and how the scheduler is named:
         `squeue -h -o '%j|%u|%k|%o' | grep -E '^dask-gateway' | head`
   - [ ] JupyterHub (batchspawner), default `^(spawner-)?jupyterhub`:
         `squeue -h -o '%j %u %b' | grep -E '^(spawner-)?jupyterhub' | head`
   - [ ] Nothing found although such jobs run → list the commonest names and
         adjust the patterns in the server configuration:
         `squeue -h -o '%j' | sed -E 's/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -30`

7. **Sign and install the app**
   - [ ] Apple developer team set; identifiers `de.awi.slurm-monitor`,
         `de.awi.slurm-monitor.widgets` and app group
         `group.de.awi.slurm-monitor` registered.
   - [ ] `xcodegen generate`, archive, install (TestFlight or direct).
   - [ ] In the app: server URL, sign in; each widget shows live data; with
         the VPN off the widgets show "VPN needed".
