#!/usr/bin/env bash
# Prints the UDID of the newest available simulator of a family ("iPhone" by
# default, or "iPad") on the newest iOS runtime that the selected Xcode's SDK
# can run. Diagnostics go to stderr.
set -euo pipefail

family="${1:-iPhone}"
sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null || echo "")"
devices_json="$(xcrun simctl list devices available -j)"

DEVICES_JSON="$devices_json" python3 - "$family" "$sdk_version" <<'PY'
import json
import os
import re
import sys

family, sdk = sys.argv[1], sys.argv[2]
data = json.loads(os.environ["DEVICES_JSON"])


def version_tuple(text):
    return tuple(int(p) for p in re.findall(r"\d+", text))


sdk_v = version_tuple(sdk)[:2] if sdk else None
candidates = []
for runtime, devices in data.get("devices", {}).items():
    m = re.search(r"SimRuntime\.iOS-(\d+(?:-\d+)*)$", runtime)
    if not m:
        continue
    rt_v = version_tuple(m.group(1))
    for d in devices:
        if not d.get("isAvailable", True) or not d["name"].startswith(family):
            continue
        nums = re.findall(r"\d+", d["name"])
        model = int(nums[0]) if nums else 0
        candidates.append((rt_v, model, d["name"], d["udid"]))

if not candidates:
    sys.exit(f"no available {family} simulator found")


def best(pool):
    # newest runtime, then highest model number, then shortest name
    # (the plain model before Pro / Plus / Max variants)
    return sorted(pool, key=lambda c: (c[0], c[1], -len(c[2])))[-1]


pool = candidates
if sdk_v:
    not_newer = [c for c in candidates if c[0][:2] <= sdk_v]
    same_major = [c for c in candidates if c[0][:1] == sdk_v[:1]]
    pool = not_newer or same_major or candidates

rt, _, name, udid = best(pool)
print(f"chose {name} on iOS {'.'.join(map(str, rt))} (SDK {sdk or 'unknown'})", file=sys.stderr)
print(udid)
PY
