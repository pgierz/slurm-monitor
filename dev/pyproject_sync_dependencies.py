#!/usr/bin/env python3
"""
Syncs the dependencies in pyproject.toml between [tool.pixi.dependencies] and [project.dependencies] sections.
"""
from pathlib import Path

import toml


def sync_from_pixi(pyproject_path: Path):
    # Load pyproject.toml
    data = toml.load(pyproject_path)

    # Get tool.pixi.dependencies
    pixi_deps = data.get("tool", {}).get("pixi", {}).get("dependencies", {})
    if not isinstance(pixi_deps, dict):
        raise ValueError("Expected [tool.pixi.dependencies] to be a dict")

    # Set project.dependencies to match tool.pixi.dependencies
    project = data.setdefault("project", {})
    project["dependencies"] = sorted(
        f"{k}{v}" for k, v in pixi_deps.items() if k and v
    )  # remove duplicates, sort for stability

    # Write back
    pyproject_path.write_text(toml.dumps(data), encoding="utf-8")
    print(
        f"Synchronized [project.dependencies] from [tool.pixi.dependencies] in: {pyproject_path}"
    )


if __name__ == "__main__":
    sync_from_pixi(Path("pyproject.toml"))
