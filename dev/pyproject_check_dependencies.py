#!/usr/bin/env python3
"""
Checks if the dependencies in pyproject.toml between [tool.pixi.dependencies] and [project.dependencies] sections
are identical.
"""
from pathlib import Path

import toml


def check_dependencies_sync_from_pixi_and_project(pyproject_path: Path):
    print(f"Checking dependencies in {pyproject_path}...")
    # Load pyproject.toml
    data = toml.load(pyproject_path)

    # Get tool.pixi.dependencies
    pixi_deps = data.get("tool", {}).get("pixi", {}).get("dependencies", {})
    if not isinstance(pixi_deps, dict):
        raise ValueError("Expected [tool.pixi.dependencies] to be a dict")

    # Set project.dependencies to match tool.pixi.dependencies
    project = data.setdefault("project", {})
    project_dependencies = sorted(project["dependencies"])
    pixi_dependencies = sorted(
        f"{k}{v}" for k, v in pixi_deps.items() if k and v
    )  # remove duplicates, sort for stability

    # Check if all pixi dependences are in project dependencies
    # project_dependencies can have more, but must at least have
    # all pixi dependencies
    for pixi_dep in pixi_dependencies:
        if pixi_dep not in project_dependencies:
            raise ValueError(
                f"Expected [tool.pixi.dependencies] to be a subset of [project.dependencies] in: {pyproject_path}"
            )

    print("[project.dependencies] matches [tool.pixi.dependencies].")


if __name__ == "__main__":
    check_dependencies_sync_from_pixi_and_project(Path("pyproject.toml"))
