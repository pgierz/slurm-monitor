"""The server's output against docs/contract.md.

Three checks: the committed samples are current server output; every family
response validates against the pydantic response models; and the key sets of
the responses equal those of the JSON examples in the contract document.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

import pytest

from make_contract_samples import SAMPLES_DIRECTORY, render
from slurm_monitor_server.models import (
    FAMILY_MODELS,
    AuthConfig,
    Envelope,
    Health,
    Me,
)
from synthetic_cluster import SAMPLE_REQUESTS, Harness, build_contract_samples

CONTRACT = Path(__file__).parent.parent.parent / "docs" / "contract.md"
TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def contract_examples() -> dict[str, Any]:
    """The JSON examples of the contract, keyed by the heading above each."""
    examples: dict[str, Any] = {}
    heading = ""
    block: list[str] | None = None
    for line in CONTRACT.read_text(encoding="utf-8").splitlines():
        if block is not None:
            if line.startswith("```"):
                examples[heading] = json.loads("\n".join(block))
                block = None
            else:
                block.append(line)
        elif line.startswith("#"):
            heading = line.lstrip("#").strip().strip("`")
        elif line.startswith("```json"):
            block = []
    return examples


def key_paths(value: Any, prefix: str = "") -> set[str]:
    """All key paths of a JSON value; list elements share the path ``[]``."""
    paths: set[str] = set()
    if isinstance(value, dict):
        for key, item in value.items():
            paths.add(f"{prefix}{key}")
            paths |= key_paths(item, f"{prefix}{key}.")
    elif isinstance(value, list):
        for item in value:
            paths |= key_paths(item, f"{prefix}[].")
    return paths


def family_of(sample_name: str) -> str:
    return sample_name.split("_")[0]


@pytest.fixture(scope="module")
async def samples() -> dict[str, dict[str, Any]]:
    return await build_contract_samples()


EXAMPLES = contract_examples()
SAMPLE_NAMES = list(SAMPLE_REQUESTS)


def test_contract_document_has_the_expected_examples():
    assert {"Envelope", "Queue", "Nodes", "Qos", "Gpu", "Runners"} <= set(EXAMPLES)
    assert {"GET /api/v1/health", "GET /api/v1/auth/config", "GET /api/v1/me"} <= set(EXAMPLES)


@pytest.mark.parametrize("name", SAMPLE_NAMES)
def test_committed_samples_are_current(name, samples):
    path = SAMPLES_DIRECTORY / f"{name}.json"
    assert path.read_text(encoding="utf-8") == render(samples[name]), (
        "contract samples are out of date; run: uv run python tests/make_contract_samples.py"
    )


@pytest.mark.parametrize("name", SAMPLE_NAMES)
def test_samples_validate_against_the_response_models(name, samples):
    model = Envelope[FAMILY_MODELS[family_of(name)]]  # type: ignore[misc]
    parsed = model.model_validate(samples[name], strict=True)
    assert parsed.model_dump(mode="json") == samples[name]
    assert parsed.schema_version == 1
    assert TIMESTAMP.match(parsed.generated_at)


@pytest.mark.parametrize("name", SAMPLE_NAMES)
def test_sample_key_sets_equal_the_contract_examples(name, samples):
    example = EXAMPLES[family_of(name).capitalize()]
    assert key_paths(samples[name]["data"]) == key_paths(example)
    envelope = {key for key in samples[name] if key != "data"}
    assert envelope == {key for key in EXAMPLES["Envelope"] if key != "data"}


@pytest.mark.parametrize("form", ["wrapped", "plain"])
async def test_filtered_responses_keep_the_contract_shape(form):
    harness = Harness(form, with_gpu_metrics=True)
    await harness.poll()
    paths = {
        "queue": "/api/v1/queue?user=alice&partition=mpp&qos=12h",
        "nodes": "/api/v1/nodes?partition=gpu",
        "qos": "/api/v1/qos?user=alice",
        "gpu": "/api/v1/gpu",
        "runners": "/api/v1/runners?user=alice",
    }
    async with harness.client() as client:
        for family, path in paths.items():
            body = (await client.get(path)).json()
            Envelope[FAMILY_MODELS[family]].model_validate(body, strict=True)  # type: ignore[misc]
            assert key_paths(body["data"]) == key_paths(EXAMPLES[family.capitalize()]), family


async def test_unenveloped_endpoints_match_the_contract_examples():
    harness = Harness()
    await harness.poll()
    async with harness.client() as client:
        health = (await client.get("/api/v1/health")).json()
        config = (await client.get("/api/v1/auth/config")).json()
        me = (await client.get("/api/v1/me")).json()
    Health.model_validate(health, strict=True)
    AuthConfig.model_validate(config, strict=True)
    Me.model_validate(me, strict=True)
    assert set(health) == set(EXAMPLES["GET /api/v1/health"])
    assert set(config) == set(EXAMPLES["GET /api/v1/auth/config"])
    assert set(me) == set(EXAMPLES["GET /api/v1/me"])


def test_contract_rules_hold_in_the_samples(samples):
    def timestamps(value: Any):
        if isinstance(value, dict):
            for key, item in value.items():
                if key in ("t", "generated_at", "estimated_start") and item is not None:
                    yield item
                yield from timestamps(item)
        elif isinstance(value, list):
            for item in value:
                yield from timestamps(item)

    for sample in samples.values():
        assert all(TIMESTAMP.match(stamp) for stamp in timestamps(sample))

    queue = samples["queue"]["data"]
    counts = [entry["count"] for entry in queue["pending_by_reason"]]
    assert counts == sorted(counts, reverse=True) and all(counts) and len(counts) <= 6
    assert {entry["reason"] for entry in queue["pending_by_reason"]} <= {
        "Priority", "Resources", "QOS limit", "Dependency", "Held", "Other",
    }  # fmt: skip
    assert sum(counts) == queue["pending"]
    states = [job["state"] for job in queue["my_jobs"]]
    assert states == sorted(states, key=lambda state: state != "R") and "PD" in states
    assert len(queue["history"]) == 4 and queue["history"][-1]["running"] == queue["running"]
    stamps = [point["t"] for point in queue["history"]]
    assert stamps == sorted(stamps)

    nodes = samples["nodes"]["data"]
    totals = [partition["total"] for partition in nodes["partitions"]]
    assert totals == sorted(totals, reverse=True)
    assert sum(totals) > nodes["total"] == 240  # two nodes sit in two partitions
    for partition in nodes["partitions"]:
        names = [node["name"] for node in partition["nodes"]]
        assert names == sorted(names) and len(names) == partition["total"]

    with_metrics, without = samples["gpu"]["data"], samples["gpu_no_metrics"]["data"]
    assert with_metrics["metrics_available"] and not without["metrics_available"]
    assert without["idle_allocated"] is None
    for node in without["nodes"]:
        for card in node["cards"]:
            assert card["state"] in ("allocated", "free", "drained", "down")
            assert card["utilisation"] is None and card["memory_total_mib"] is None
    assert all(point["utilisation"] is None for point in without["history"])
    assert all(point["utilisation"] is not None for point in with_metrics["history"])
    assert [node["type"] for node in with_metrics["nodes"]] == ["a100"] * 4 + ["a40"] * 4
    assert len(with_metrics["top_users"]) <= 5
    cards = [card for node in with_metrics["nodes"] for card in node["cards"]]
    assert (
        sum(card["state"] in ("busy", "idle_allocated", "allocated") for card in cards)
        == (with_metrics["allocated"])
    )

    runners = samples["runners"]["data"]
    owners = [(cluster["owner"], cluster["id"]) for cluster in runners["dask"]["clusters"]]
    assert owners == sorted(owners)
