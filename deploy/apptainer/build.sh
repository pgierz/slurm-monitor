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
  RUNTIME=apptainer
elif singularity --version >/dev/null 2>&1; then
  RUNTIME=singularity
else
  echo "neither apptainer nor singularity found in PATH" >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  FAKEROOT_FLAG="--fakeroot"
else
  FAKEROOT_FLAG=""
fi

echo "Building ${OUT} with ${RUNTIME} (${FAKEROOT_FLAG:-as root})"
"${RUNTIME}" build ${FAKEROOT_FLAG} "${OUT}" "${DEF}"

echo "Built: ${OUT}"
"${RUNTIME}" inspect "${OUT}" || true
