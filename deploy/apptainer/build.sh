#!/usr/bin/env bash
# Build the slurm-monitor-exporter Apptainer image.
#
# Usage:
#   deploy/apptainer/build.sh [output.sif]
#
# Run from the repo root. Requires Apptainer >= 1.2 with --fakeroot or root.

set -euo pipefail

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
