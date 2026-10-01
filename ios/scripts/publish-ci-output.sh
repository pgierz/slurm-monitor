#!/usr/bin/env bash
# Usage: publish-ci-output.sh <job-name> <path>...
# Publishes condensed logs and screenshots of this run to the branch
# `ci-output` under runs/<short sha>/<job-name>/, so they can be read with a
# plain `git fetch` (job logs and artefacts need an authenticated download).
# Log files are reduced to their error lines plus their tail.
set -uo pipefail

job="$1"
shift
sha="$(git rev-parse --short=7 HEAD)"
work="$(mktemp -d)"
dest="$work/out/runs/$sha/$job"
mkdir -p "$dest"

for path in "$@"; do
  [ -e "$path" ] || continue
  if [ -d "$path" ]; then files="$(find "$path" -type f)"; else files="$path"; fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      *.png) cp "$f" "$dest/" ;;
      *.log|*.txt)
        {
          echo "===== $(basename "$f"): matching lines ====="
          grep -n -E "error:|: error|warning: unre|FAILED|Testing failed|failed|Fatal error|XCTAssert|Executed [0-9]+ test|passed|skipped" "$f" | head -n 400
          echo "===== $(basename "$f"): last 60 lines ====="
          tail -n 60 "$f"
        } > "$dest/$(basename "$f").summary.txt"
        ;;
    esac
  done <<< "$files"
done
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$dest/published_at.txt"

remote="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
for attempt in 1 2 3 4 5; do
  rm -rf "$work/repo"
  if git clone -q --depth 1 --branch ci-output "$remote" "$work/repo" 2>/dev/null; then
    :
  else
    mkdir -p "$work/repo" && git -C "$work/repo" init -q && git -C "$work/repo" checkout -q --orphan ci-output
    git -C "$work/repo" remote add origin "$remote"
  fi
  mkdir -p "$work/repo/runs/$sha"
  rm -rf "$work/repo/runs/$sha/$job"
  cp -R "$dest" "$work/repo/runs/$sha/$job"
  # Keep the branch small: only the eight most recent runs stay.
  (cd "$work/repo/runs" && ls -t | tail -n +9 | xargs -I{} rm -rf "{}")
  echo "$sha" > "$work/repo/LATEST"
  git -C "$work/repo" add -A
  git -C "$work/repo" -c user.name="ci" -c user.email="ci@users.noreply.github.com" commit -q -m "CI output for $sha ($job)" || exit 0
  if git -C "$work/repo" push -q origin ci-output; then
    echo "Published to ci-output: runs/$sha/$job"
    exit 0
  fi
  sleep $((attempt * 3))
done
echo "::warning::Could not publish CI output."
exit 0
