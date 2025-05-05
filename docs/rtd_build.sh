#!/usr/bin/env bash
set -euxo pipefail
OUTPUT_DIR="${READTHEDOCS_OUTPUT:-docs/_build}"
sphinx-build -b html docs "${OUTPUT_DIR}/html"
