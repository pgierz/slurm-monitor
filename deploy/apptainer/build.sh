#!/usr/bin/env bash
# Build the slurm-monitor-exporter Apptainer image.
#
# Usage:
#   deploy/apptainer/build.sh [output.sif]
#
# Run from the repo root. Requires Apptainer >= 1.2 with --fakeroot or root.
# On Albedo, run as root (sudo) — fakeroot is not available there.

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

# Login-node RAM is not enough for squashfs creation; build on a compute node.
# Disable by exporting SLURM_MONITOR_BUILD_ON_COMPUTE=0.
if [[ "${SLURM_MONITOR_BUILD_ON_COMPUTE:-1}" != "0" ]] && command -v srun >/dev/null 2>&1; then
  SRUN_ACCOUNT="${SLURM_MONITOR_BUILD_ACCOUNT:-computing.computing}"
  SRUN_MEM="${SLURM_MONITOR_BUILD_MEM:-32G}"
  SRUN_TIME="${SLURM_MONITOR_BUILD_TIME:-00:30:00}"
  RUNTIME=(srun -A "${SRUN_ACCOUNT}" --mem="${SRUN_MEM}" --time="${SRUN_TIME}" "${RUNTIME[@]}")
fi

if [[ "${EUID}" -ne 0 ]]; then
  FAKEROOT_FLAG=(--fakeroot)
else
  FAKEROOT_FLAG=()
fi

echo "Building ${OUT} with: ${RUNTIME[*]}"
"${RUNTIME[@]}" build "${FAKEROOT_FLAG[@]}" "${OUT}" "${DEF}"

echo "Built: ${OUT}"
# inspect cannot run under srun wrapper if shell propagation is off; run plain.
if command -v apptainer >/dev/null 2>&1; then
  apptainer inspect "${OUT}" || true
elif command -v singularity >/dev/null 2>&1; then
  singularity inspect "${OUT}" || true
fi
