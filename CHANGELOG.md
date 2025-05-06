# CHANGELOG


## v0.4.1 (2025-05-05)

### Bug Fixes

- Dependency in pixi still had old package name
  ([#21](https://github.com/pgierz/slurm-monitor/pull/21),
  [`d26c2e0`](https://github.com/pgierz/slurm-monitor/commit/d26c2e00ff1968a5bfea2fdf8b7e4725afec22ce))

* wip: first ci draft to see if you can automatically test install a development version

wip: enables the linux x86 platform for pixi installs in pyproject.toml

squash: ...should have been linux-64 as platform name

- Dependency in pixi still had old package name
  ([#21](https://github.com/pgierz/slurm-monitor/pull/21),
  [`d26c2e0`](https://github.com/pgierz/slurm-monitor/commit/d26c2e00ff1968a5bfea2fdf8b7e4725afec22ce))

### Continuous Integration

- ...doesn't need pixi install ([#21](https://github.com/pgierz/slurm-monitor/pull/21),
  [`d26c2e0`](https://github.com/pgierz/slurm-monitor/commit/d26c2e00ff1968a5bfea2fdf8b7e4725afec22ce))

* wip: relocks pixi

- Try for auto changelog
  ([`f02134a`](https://github.com/pgierz/slurm-monitor/commit/f02134ab32074049e4d98598ffe9b581c69d4424))

- Try for auto changelog ...2 ([#22](https://github.com/pgierz/slurm-monitor/pull/22),
  [`e286209`](https://github.com/pgierz/slurm-monitor/commit/e286209dd060bfffaeaf61152c3efb5f6745573d))

- Try for auto changelog ...3 ([#23](https://github.com/pgierz/slurm-monitor/pull/23),
  [`a7d1356`](https://github.com/pgierz/slurm-monitor/commit/a7d13560f12827fc447d44f65efb2d56d741052c))

- Try for auto changelog ...4 ([#24](https://github.com/pgierz/slurm-monitor/pull/24),
  [`88c4bc2`](https://github.com/pgierz/slurm-monitor/commit/88c4bc264cccad1290d44e15fca97f6a0b527f58))


## v0.4.0 (2025-05-04)

### Features

- First plotting dasboard seems to work ([#18](https://github.com/pgierz/slurm-monitor/pull/18),
  [`5fdb958`](https://github.com/pgierz/slurm-monitor/commit/5fdb958ef03ff77be0bff746e5a8d5bdd3947eac))

Signed-off-by: Paul Gierz <pgierz@awi.de>


## v0.3.0 (2025-05-03)

### Features

- Seperates REST, CLI, and slurm vs slurmdb ([#13](https://github.com/pgierz/slurm-monitor/pull/13),
  [`a07bbcb`](https://github.com/pgierz/slurm-monitor/commit/a07bbcb8e98f9118832e62bc88da45f9d8444a3e))

* wip: separated out rest and cli backends. rest still works.

* wip: adds slurm-db show command, rearranges pixi tasks to be alphabetical

* wip: minor typos in readme

* wip: pixi lock re-committed

* wip: separated out slurm from slurmdb backend switches

* wip: seperated slurm data fetching for slurm and slurmdb endpoints


## v0.2.0 (2025-05-03)

### Build System

- **pyproject.toml**: Adds dependencies for sdist install
  ([#4](https://github.com/pgierz/slurm-monitor/pull/4),
  [`e00a264`](https://github.com/pgierz/slurm-monitor/commit/e00a264b24e714d5677a2893f3813fe31dee0b24))

* wip: correct the dependencies table formatting

* wip... 1

* wip... 2

* wip: adds utility script to sync dependencies

* wip: adds pre-commit and runs once

* wip: checks dependency sync via git precommit hook

### Chores

- Cleans up old markdown files (#10) ([#9](https://github.com/pgierz/slurm-monitor/pull/9),
  [`e450683`](https://github.com/pgierz/slurm-monitor/commit/e450683179150cce44735a18ad875496e952f153))

- **.github**: Adds issue and pr templates ([#9](https://github.com/pgierz/slurm-monitor/pull/9),
  [`e450683`](https://github.com/pgierz/slurm-monitor/commit/e450683179150cce44735a18ad875496e952f153))

- **github**: Mixed up template formatting, wip... 1
  ([#9](https://github.com/pgierz/slurm-monitor/pull/9),
  [`e450683`](https://github.com/pgierz/slurm-monitor/commit/e450683179150cce44735a18ad875496e952f153))

### Features

- Includes bumpversion config
  ([`46ce83a`](https://github.com/pgierz/slurm-monitor/commit/46ce83a9399b413d091e725eb1c2f90b32e93b7b))

- Tested endpoint /slum via REST ([#11](https://github.com/pgierz/slurm-monitor/pull/11),
  [`205556b`](https://github.com/pgierz/slurm-monitor/commit/205556b3e6704c66120dcbb6e24072d635001699))

* wip(dlt_sources): deactivates slurmdb/jobs endpoint

* wip(dlt_sources): endpoint /slurm/diag/ seem to work

* wip(dlt_sources): endpoint /slurm/licenses/ seem to work

* wip(dlt_sources): endpoint /slurm/jobs/ seem to work

* wip(dlt_sources): endpoint /slurm/job/{job_id} seem to work

* wip(dlt_sources): endpoint /slurm/nodes/{node} seem to work

* wip(dlt_sources): endpoint /slurm/nodes/{partition} seem to work

* wip(dlt_sources): endpoint /slurm/nodes/{reservation} seem to work

* wip(dlt_sources): final touches for REST /slurm/<THING endpoint paginator

* wip(dlt_sources): hides debugging output behind a ENV VAR switch

* wip(dlt_sources): minor fixes in the endpoints /licenses and /reservations


## v0.1.0 (2025-05-02)
