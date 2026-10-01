#!/usr/bin/env bash
# Usage: run-xcodebuild.sh <raw-log-file> <xcodebuild arguments...>
# Runs xcodebuild, keeps the raw log, prints a condensed log (through
# xcbeautify when installed) and, on failure, repeats the lines that carry
# the actual errors at the end, so they are easy to find in the job log.
set -uo pipefail

log="$1"
shift
mkdir -p "$(dirname "$log")"

if command -v xcbeautify >/dev/null 2>&1; then
  xcodebuild "$@" 2>&1 | tee "$log" | xcbeautify
else
  xcodebuild "$@" 2>&1 | tee "$log"
fi
status="${PIPESTATUS[0]}"

if [ "$status" -ne 0 ]; then
  echo
  echo "===== xcodebuild failed with status $status; error lines from $log ====="
  grep -n -E "error:|: error|\*\* .* FAILED \*\*|Testing failed|failed -|Fatal error|XCTAssert" "$log" | sort -u | head -n 200
  echo "===== last 40 lines of the raw log ====="
  tail -n 40 "$log"
fi
exit "$status"
