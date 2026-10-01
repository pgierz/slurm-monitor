# Slurm Monitor

Native iOS and iPadOS widgets that show the Slurm status of an HPC cluster:
queue, nodes, QOS, GPUs, and the CI, Dask and JupyterHub jobs running on it.
The widgets are fed by a small middle server inside the institute network
that polls slurmrestd. The first target is Albedo at AWI; nothing in the code
is specific to it.

## Architecture

```
slurmrestd ──poll──▶ middle server ──JSON snapshots──▶ app ──▶ shared cache ──▶ widgets
                         ▲                              (app group, keychain)
GPU metrics source ──────┘
```

- **slurmrestd** is polled about once a minute by a service user that may
  read all jobs.
- **The middle server** (`server/`, Python, FastAPI) reduces the large
  slurmrestd payloads to compact records, keeps a few hours of history in
  memory and serves one small JSON snapshot per widget family under
  `/api/v1/{queue,nodes,qos,gpu,runners}`. It is reachable over VPN only.
  Clients authenticate with a static bearer token or with Helmholtz AAI
  (OIDC, authorization code flow with PKCE).
- **The app** (`ios/App`) holds the server address and the sign-in, and shows
  each family in full. **The widgets** (`ios/Widgets`) read the same
  snapshots; both share the Swift package `SlurmKit` (models, client, cache,
  credentials, state logic).

The shapes exchanged between server and app are fixed by `docs/contract.md`.
Where code and contract disagree, the contract decides.

Every widget is in one of four states:

| State | Shown |
|---|---|
| Live | the current snapshot |
| Stale | the normal layout in grey, with "as of HH:mm" in the header: the server answered from an older poll |
| VPN needed | the server could not be reached; the key figures of the last snapshot as "last seen" |
| Sign in needed | no valid credentials; no data, tap to open the app |

Before a server address has been entered, the widgets say "Not configured".

## Widgets

| Widget | Sizes | Shows |
|---|---|---|
| Queue | small, medium, large | running and pending jobs, pending by reason, my jobs |
| Nodes | small, medium, extra large (iPad) | allocated, idle, drained and down nodes; by partition; one cell per node |
| QOS | medium | CPUs in use against the limit per QOS, fairshare |
| GPU | small, medium, large, extra large (iPad) | allocated cards by type, idle-allocated cards, six-hour history, one cell per card |
| CI runners | small | runners alive, jobs waiting, oldest wait |
| Dask clusters | medium | workers and time left per cluster |
| JupyterHub | small | sessions, with a GPU, near walltime |
| Cluster at a glance (Lock Screen) | circular, rectangular, inline | allocated node fraction; next job start; `12 R · 3 PD` |

`docs/mockups.md` describes the approved designs.

## First deployment

`docs/deployment-checklist.md` lists the steps in order: service user and
token, recording real slurmrestd payloads, the GPU metrics source, the
Helmholtz AAI client (`docs/helmholtz-aai.md`), installing the server,
confirming the job name patterns, and signing and installing the app.

## Trying it without a cluster

The server has a demo mode that serves a synthetic cluster (240 nodes, four
partitions, A40 and A100 cards, CI runners, Dask clusters, JupyterHub
sessions) and contacts no slurmrestd:

```sh
cd server
uv sync
uv run slurm-monitor-server --demo
curl -H 'Authorization: Bearer demo' 'http://127.0.0.1:8080/api/v1/queue?user=alice'
```

Without a configuration file the bearer token is `demo`.

For the app, on a Mac with Xcode and XcodeGen:

```sh
cd ios
xcodegen
open SlurmMonitor.xcodeproj
```

Run the scheme `SlurmMonitor` in a simulator; no signing setup is needed
there. In the app's settings enter `http://127.0.0.1:8080` as the server and
`demo` as the access token, then add the widgets to the Home Screen. For a
phone on the same network, start the server with `--host 0.0.0.0`.
`server/README.md` and `ios/README.md` have the details.

## Screenshots from CI

The workflow `.github/workflows/ios.yml` builds the app on macOS and renders
every widget to PNG in the simulator, from the sample data in `SlurmKit`. The
screenshots and the condensed build logs are published to the branch
`ci-output` under `runs/<short sha>/app/`; the output of the `SlurmKit` tests
is beside them under `runs/<short sha>/slurmkit/`. The PNGs are also attached
to the workflow run as the artifact `widget-screenshots`.

## Layout of the repository

```
server/                     the middle server (Python, FastAPI)
  src/slurm_monitor_server/ the package
  tests/                    pytest, with synthetic slurmrestd fixtures
  deploy/                   Containerfile, systemd unit, example configuration
  tools/                    dump script for real payloads, GPU metrics collector
ios/
  project.yml               XcodeGen project definition (no .xcodeproj in git)
  SlurmKit/                 Swift package: models, client, cache, credentials, state logic
  App/                      the app
  Widgets/                  the widget extension
  ScreenshotTests/          renders every widget to PNG in the simulator
  scripts/                  helpers used by CI and usable locally
docs/
  contract.md               the data contract between server and app
  mockups.md                the visual reference for the widgets
  deployment-checklist.md   first deployment on a real cluster
  helmholtz-aai.md          registering the app with Helmholtz AAI
  team-notes.md             working notes for contributors
.github/workflows/          server tests (Linux), app build and tests (macOS)
```

## Status

- The server has been built and tested against synthetic slurmrestd data
  only. It has not yet been run against a real cluster. Field names, state
  and reason strings and the GRES format are to be checked against recorded
  payloads first; the deployment checklist has a step for that.
- The Helmholtz AAI sign-in is implemented in the app and the server but has
  not been tried against the real identity provider. Several points about
  the provider are unverified and listed in `docs/helmholtz-aai.md`. The
  static token sign-in does not depend on any of them.
- Per-card GPU metrics (utilisation, memory, temperature, power, and with
  them the "allocated but idle" count) need a metrics source: a DCGM exporter
  behind Prometheus, or the collector in `server/tools`. Without one the GPU
  widgets show allocation only.
- The widgets have so far been seen only in the simulator, as rendered by
  the screenshot tests, not on a device.

The earlier PyConDE 2025 experiment is kept on the branch
`legacy/pyconde-2025`.
