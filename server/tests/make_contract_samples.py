"""Write tests/data/contract_samples/*.json from the synthetic cluster.

Run from the server directory::

    uv run python tests/make_contract_samples.py

The files are real server output; the Swift tests decode them. A test
(``test_contract.py``) fails when they are out of date.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

from synthetic_cluster import build_contract_samples

SAMPLES_DIRECTORY = Path(__file__).parent / "data" / "contract_samples"


def render(sample: dict[str, Any]) -> str:
    return json.dumps(sample, indent=2, ensure_ascii=False) + "\n"


def main() -> None:
    SAMPLES_DIRECTORY.mkdir(parents=True, exist_ok=True)
    for name, sample in asyncio.run(build_contract_samples()).items():
        path = SAMPLES_DIRECTORY / f"{name}.json"
        path.write_text(render(sample), encoding="utf-8")
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
