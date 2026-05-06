#!/usr/bin/env bash
# Build the slurm-monitor-exporter Apptainer image.
#
# Usage:
#   ./deploy/apptainer/build.sh [output.sif]
#
# Default mode is `remote`: the build runs on the Sylabs cloud builder.
# This avoids login-node RAM limits, sudo, fakeroot, and srun.
#
# One-time setup for remote mode:
#   1. Create a token at https://cloud.sylabs.io  ->  Access Tokens
#   2. apptainer remote login    # paste the token
#
# Modes (set with SLURM_MONITOR_BUILD_MODE):
#   remote   apptainer build --remote ... (default)
#   local    apptainer build ...           (needs root or --fakeroot + RAM)
#   srun     wrap `local` in srun on a compute node
#
# Common env overrides:
#   SLURM_MONITOR_BUILD_MODE=remote|local|srun   default: remote
#   SLURM_MONITOR_BUILD_ACCOUNT=<acct>           srun: -A <acct>  (unset = SLURM default)
#   SLURM_MONITOR_BUILD_PARTITION=<part>         srun: -p <part>
#   SLURM_MONITOR_BUILD_MEM=32G                  srun: --mem
#   SLURM_MONITOR_BUILD_TIME=00:30:00            srun: --time
#
# Note on remote mode: the entire repo (the directory containing the .def
# file) is tarballed and uploaded to Sylabs cloud as the build context.
# Make sure no secrets sit in the working tree.

set -euo pipefail

# Lmod's `module` is a shell function from /etc/profile.d/*.sh and is not
# present in non-interactive bash (e.g. under `sudo`). Source it ourselves.
if ! command -v module >/dev/null 2>&1; then
  for init in /etc/profile.d/lmod.sh /etc/profile.d/z00_lmod.sh /etc/profile.d/modules.sh; do
    if [[ -r "$init" ]]; then
      # shellcheck disable=SC1090
      source "$init"
      break
    fi
  done
fi
if command -v module >/dev/null 2>&1; then
  module load apptainer 2>/dev/null || true
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
DEF="${REPO_ROOT}/deploy/apptainer/slurm-monitor-exporter.def"
OUT="${1:-${REPO_ROOT}/dist/slurm-monitor-exporter.sif}"

mkdir -p "$(dirname "${OUT}")"

cd "${REPO_ROOT}"

if apptainer --version >/dev/null 2>&1; then
  RUNTIME=(apptainer)
elif singularity --version >/dev/null 2>&1; then
  RUNTIME=(singularity)
else
  echo "neither apptainer nor singularity found in PATH" >&2
  exit 1
fi

MODE="${SLURM_MONITOR_BUILD_MODE:-remote}"

REMOTE_FLAG=()
case "${MODE}" in
  remote)
    REMOTE_FLAG=(--remote)
    # Sanity-check that a remote endpoint is configured; otherwise the build
    # fails late with a less-friendly error.
    if ! "${RUNTIME[@]}" remote status >/dev/null 2>&1; then
      cat >&2 <<'EOF'
[build.sh] No remote endpoint configured for apptainer.

Run once:
  apptainer remote login
(get a token from https://cloud.sylabs.io -> Access Tokens)

Or set SLURM_MONITOR_BUILD_MODE=local|srun to skip the remote builder.
EOF
      exit 2
    fi
    ;;
  local)
    : # nothing extra
    ;;
  srun)
    if ! command -v srun >/dev/null 2>&1; then
      echo "[build.sh] mode=srun but srun not in PATH" >&2
      exit 2
    fi
    SRUN_ARGS=(--mem="${SLURM_MONITOR_BUILD_MEM:-32G}" --time="${SLURM_MONITOR_BUILD_TIME:-00:30:00}")
    [[ -n "${SLURM_MONITOR_BUILD_ACCOUNT:-}"  ]] && SRUN_ARGS=(-A "${SLURM_MONITOR_BUILD_ACCOUNT}"  "${SRUN_ARGS[@]}")
    [[ -n "${SLURM_MONITOR_BUILD_PARTITION:-}" ]] && SRUN_ARGS=(-p "${SLURM_MONITOR_BUILD_PARTITION}" "${SRUN_ARGS[@]}")
    RUNTIME=(srun "${SRUN_ARGS[@]}" "${RUNTIME[@]}")
    ;;
  *)
    echo "[build.sh] invalid SLURM_MONITOR_BUILD_MODE=${MODE} (expected: remote|local|srun)" >&2
    exit 2
    ;;
esac

# fakeroot only matters for non-remote, non-root builds.
FAKEROOT_FLAG=()
if [[ "${MODE}" != "remote" && "${EUID}" -ne 0 ]]; then
  FAKEROOT_FLAG=(--fakeroot)
fi

echo "[build.sh] mode=${MODE} out=${OUT}"
echo "[build.sh] cmd: ${RUNTIME[*]} build ${REMOTE_FLAG[*]:-} ${FAKEROOT_FLAG[*]:-} ${OUT} ${DEF}"
"${RUNTIME[@]}" build "${REMOTE_FLAG[@]}" "${FAKEROOT_FLAG[@]}" "${OUT}" "${DEF}"

echo "[build.sh] built: ${OUT}"
if command -v apptainer >/dev/null 2>&1; then
  apptainer inspect "${OUT}" || true
elif command -v singularity >/dev/null 2>&1; then
  singularity inspect "${OUT}" || true
fi
