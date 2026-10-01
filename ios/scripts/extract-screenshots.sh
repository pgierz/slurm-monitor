#!/usr/bin/env bash
# Usage: extract-screenshots.sh <path to .xcresult> <output directory> [directly written directory]
#
# Exports the PNG attachments of a test run from the result bundle and names
# them after the attachment names given by WidgetSnapshotter. If the export
# yields nothing (older xcresulttool, or no attachments), PNGs that the tests
# wrote directly (SNAPSHOT_OUTPUT_DIR) are copied instead.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <xcresult> <output-dir> [direct-dir]" >&2
  exit 2
fi

xcresult="$1"
out="$2"
direct="${3:-}"
mkdir -p "$out"

raw="$(mktemp -d)"
trap 'rm -rf "$raw"' EXIT

if [ -d "$xcresult" ] && xcrun xcresulttool export attachments --path "$xcresult" --output-path "$raw"; then
  if [ -f "$raw/manifest.json" ]; then
    python3 - "$raw" "$out" <<'PY'
import json
import os
import re
import shutil
import sys

raw, out = sys.argv[1], sys.argv[2]
with open(os.path.join(raw, "manifest.json")) as fh:
    manifest = json.load(fh)

# suggestedHumanReadableName looks like "<attachment name>_<n>_<UUID>.png"
suffix = re.compile(r"_\d+_[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")
used = set()
for test in manifest:
    for att in test.get("attachments", []):
        exported = att.get("exportedFileName")
        if not exported or not exported.lower().endswith(".png"):
            continue
        source = os.path.join(raw, exported)
        if not os.path.isfile(source):
            continue
        suggested = att.get("suggestedHumanReadableName") or exported
        stem = suffix.sub("", os.path.splitext(suggested)[0]) or os.path.splitext(exported)[0]
        stem = re.sub(r"[^A-Za-z0-9._-]+", "-", stem)
        name, n = stem, 2
        while name in used:
            name = f"{stem}-{n}"
            n += 1
        used.add(name)
        shutil.copyfile(source, os.path.join(out, name + ".png"))
        print(f"exported {name}.png  ({test.get('testIdentifier', '?')})")
PY
  else
    echo "no manifest.json in the export; copying PNGs under their exported names" >&2
    find "$raw" -name '*.png' -exec cp {} "$out"/ \;
  fi
else
  echo "xcresulttool export attachments failed or result bundle missing: $xcresult" >&2
fi

count="$(find "$out" -name '*.png' | wc -l | tr -d ' ')"
if [ "$count" -eq 0 ] && [ -n "$direct" ] && [ -d "$direct" ]; then
  echo "falling back to PNGs written directly to $direct" >&2
  find "$direct" -name '*.png' -exec cp {} "$out"/ \;
  count="$(find "$out" -name '*.png' | wc -l | tr -d ' ')"
fi

echo "$count screenshot(s) in $out"
ls -l "$out"
[ "$count" -gt 0 ]
