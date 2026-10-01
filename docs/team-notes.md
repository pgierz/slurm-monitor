# Working notes for contributors

## What this is

Native iOS and iPadOS widgets that show the Slurm status of an HPC cluster
(first target: Albedo at AWI), fed by a small middle server that polls
slurmrestd. The data contract is `docs/contract.md`; the visual reference is
`docs/mockups.md`.

## Layout

```
server/                     Python middle server (FastAPI)
  src/slurm_monitor_server/ package
  tests/                    pytest, with synthetic slurmrestd fixtures
  deploy/                   Containerfile, systemd unit, example configuration
  tools/                    dump script for recording real payloads
ios/
  project.yml               XcodeGen project definition (no .xcodeproj in git)
  SlurmKit/                 Swift package: models, client, cache, credentials, state logic
  App/                      the app target
  Widgets/                  the widget extension
  ScreenshotTests/          renders every widget to PNG in the simulator
docs/
.github/workflows/          server tests (Linux), app build and tests (macOS)
```

## Rules

- The contract decides. If the contract seems wrong, say so in your report;
  do not silently diverge.
- No host names, user names, tokens or account names in code. They belong in
  configuration. Examples use `slurm.example.org`.
- Names are structural and plain (`QueueAggregator`, `SnapshotStore`), no
  mythology, no cleverness.
- Prose in docs and comments: plain, craftsman register. Write "finished",
  "released", "published"; avoid "shipping", "landed", "stakeholders".
- British spelling in user-facing text ("utilisation").
- App name "Slurm Monitor", bundle identifier `de.awi.slurm-monitor`,
  widget extension `de.awi.slurm-monitor.widgets`, app group
  `group.de.awi.slurm-monitor`. Deployment target iOS and iPadOS 18.0.
- The Linux workspace cannot compile Swift. Swift is verified only by CI on
  macOS, so write conservative, well-known API usage and keep `SlurmKit`
  free of UIKit so `swift test` works on a plain macOS runner.
- Do not run `git` commands that change state (commit, push, checkout,
  stash). The coordinator commits. Stay inside the directories you were
  given.
