"""Odd input: out-of-range values, misspelt settings, requests the framework refuses."""

from __future__ import annotations

import logging
from pathlib import Path

import httpx
import pytest

from slurm_monitor_server.aggregators import GpuAggregator, QueueAggregator
from slurm_monitor_server.config import GpuSettings, RunnerSettings, load_settings
from slurm_monitor_server.history import HistoryStore
from slurm_monitor_server.records import ClusterState
from slurm_monitor_server.reduce import (
    MAX_CARDS_PER_NODE,
    RunnerClassifier,
    jobs_without_user_name,
    reduce_job,
    reduce_jobs,
    reduce_node,
    reduce_nodes,
)
from slurm_monitor_server.slurm_parsing import parse_int, parse_timestamp
from synthetic_cluster import NOW, STATIC_TOKEN, Harness

CLASSIFIER = RunnerClassifier(RunnerSettings())
CONTRACT = Path(__file__).parent.parent.parent / "docs" / "contract.md"
JOBS_PATH = "/slurm/v0.0.40/jobs"


def number(value: int) -> dict:
    return {"set": True, "infinite": False, "number": value}


# ----- out-of-range values -----------------------------------------------------


@pytest.mark.parametrize("raw", [2**62, number(2**62), 2**63 - 1, "1e30", float("inf"), -5, 0])
def test_out_of_range_timestamps_are_unknown(raw):
    assert parse_timestamp(raw) is None


def test_non_finite_numbers_are_unset():
    for raw in (float("inf"), float("-inf"), float("nan"), "inf", "nan", "1e999"):
        assert parse_int(raw) is None
    assert parse_timestamp(NOW) == NOW


async def test_absurd_job_times_give_null_not_a_server_error():
    harness = Harness()
    huge = number(2**62)
    odd = [
        {"job_id": 990001, "name": "odd-pending", "user_name": "zed", "job_state": ["PENDING"],
         "state_reason": "Priority", "partition": "mpp", "qos": "12h", "submit_time": huge,
         "start_time": huge, "time_limit": huge, "node_count": number(1), "cpus": number(4)},
        {"job_id": 990002, "name": "odd-running", "user_name": "zed", "job_state": ["RUNNING"],
         "state_reason": "None", "partition": "gpu", "qos": "12h", "submit_time": huge,
         "start_time": huge, "time_limit": huge, "node_count": number(1), "cpus": number(4),
         "tres_per_node": "gres/gpu:a100:1"},
        {"job_id": 990003, "name": "odd-gpu-wait", "user_name": "zed", "job_state": ["PENDING"],
         "state_reason": "Resources", "partition": "gpu", "qos": "12h", "submit_time": huge,
         "start_time": number(0), "time_limit": number(60), "tres_per_node": "gres/gpu:a100:1"},
    ]  # fmt: skip
    harness.slurmrestd.rewrite[JOBS_PATH] = lambda payload: {
        **payload,
        "jobs": [*payload["jobs"], *odd],
    }
    assert await harness.poll()
    async with harness.client() as client:
        for family in ("queue?user=zed", "nodes", "qos?user=zed", "gpu", "runners?user=zed"):
            response = await client.get(f"/api/v1/{family}")
            assert response.status_code == 200, family
        queue = (await client.get("/api/v1/queue?user=zed")).json()["data"]
    by_id = {job["job_id"]: job for job in queue["my_jobs"]}
    assert by_id[990001]["estimated_start"] is None
    assert by_id[990001]["time_limit_seconds"] is None
    assert by_id[990002]["elapsed_seconds"] == 0
    assert by_id[990002]["time_limit_seconds"] is None


def test_gres_card_count_is_capped_per_node():
    huge = reduce_node(
        {"name": "gpu-001", "state": ["IDLE"], "gres": "gpu:a100:100000", "gres_used": ""},
        {},
        "gpu",
    )
    assert len(huge.gpu_types) == MAX_CARDS_PER_NODE == 64
    mixed = reduce_node(
        {"name": "gpu-002", "state": ["MIXED"], "gres": "gpu:a100:40,gpu:a40:40",
         "gres_used": "gpu:a100:2(IDX:0,70)"}, {}, "gpu",
    )  # fmt: skip
    assert mixed.gpu_types == ("a100",) * 40 + ("a40",) * 24
    assert mixed.gpu_allocated == frozenset({0})
    # A count with a unit suffix ("4K") is just as absurd.
    assert len(reduce_node({"name": "g", "state": [], "gres": "gpu:4K"}, {}, "gpu").gpu_types) == 64
    # A job cannot point at cards beyond the cap either.
    job = reduce_job(
        {"job_id": 1, "job_state": ["RUNNING"], "nodes": "gpu-001",
         "gres_detail": ["gpu:a100:3(IDX:0-1,4000)"]}, CLASSIFIER, "gpu",
    )  # fmt: skip
    assert job.gpu_cards == (("gpu-001", 0), ("gpu-001", 1))


def test_future_nodes_are_left_out_entirely():
    payload = {"nodes": [
        {"name": "n1", "state": ["IDLE"], "partitions": ["mpp"]},
        {"name": "n2", "state": ["FUTURE"], "partitions": ["mpp"]},
        {"name": "n3", "state": ["IDLE", "FUTURE", "CLOUD"], "partitions": ["mpp"]},
        {"name": "n4", "state": "future", "state_flags": [], "partitions": "mpp"},
        {"name": "n5", "state": ["IDLE", "CLOUD", "POWERED_DOWN"], "partitions": ["mpp"]},
    ]}  # fmt: skip
    nodes = reduce_nodes(payload, None)
    assert [(node.name, node.state) for node in nodes] == [("n1", "idle"), ("n5", "idle")]


# ----- jobs without a user name ------------------------------------------------


def test_jobs_without_user_name_counts_running_and_pending_only():
    payload = {"jobs": [
        {"job_id": 1, "user_name": "", "job_state": ["RUNNING"]},
        {"job_id": 2, "user_name": None, "user_id": 1234, "job_state": "PENDING"},
        {"job_id": 3, "job_state": ["COMPLETED"]},
        {"job_id": 4, "user_name": "alice", "job_state": ["RUNNING"]},
    ]}  # fmt: skip
    assert jobs_without_user_name(payload) == 2
    assert jobs_without_user_name({}) == 0


async def test_empty_user_names_are_warned_about_once(caplog):
    harness = Harness()

    def blank(payload):
        jobs = [dict(job) for job in payload["jobs"]]
        for job in jobs[:3]:
            job["user_name"] = ""
        return {**payload, "jobs": jobs}

    harness.slurmrestd.rewrite[JOBS_PATH] = blank
    with caplog.at_level(logging.WARNING, logger="slurm_monitor_server.poller"):
        for _ in range(3):
            assert await harness.poll()
        warnings = [r.getMessage() for r in caplog.records if "user_name" in r.getMessage()]
        assert len(warnings) == 1 and warnings[0].startswith("3 running or pending jobs")
        # Gone and back again is a change worth another line.
        del harness.slurmrestd.rewrite[JOBS_PATH]
        assert await harness.poll()
        harness.slurmrestd.rewrite[JOBS_PATH] = blank
        assert await harness.poll()
    assert sum("user_name" in r.getMessage() for r in caplog.records) == 2


# ----- configuration -----------------------------------------------------------


@pytest.mark.parametrize(
    ("text", "where"),
    [
        ('clustr = "example"\n', "clustr"),
        ('[slurm]\nbase_ur = "https://slurm.example.org:6820"\n', "slurm.base_ur"),
        ("[poll]\ninterval = 30\n", "poll.interval"),
        ("[auth.oidc]\nrequired_entitlement = []\n", "auth.oidc.required_entitlement"),
        ("[gpu.metrics]\nsorce = 'none'\n", "gpu.metrics.sorce"),
        ('[[runners.extra]]\nkey = "m"\nlabel = "M"\npattern = "^m"\nlabl = "x"\n', "labl"),
        ("[metric]\nenabled = true\n", "metric"),
    ],
)
def test_unknown_keys_in_the_configuration_file_are_refused(monkeypatch, tmp_path, text, where):
    config = tmp_path / "config.toml"
    config.write_text(text)
    monkeypatch.setenv("SLURM_MONITOR_CONFIG", str(config))
    with pytest.raises(ValueError) as failure:
        load_settings()
    message = str(failure.value)
    assert where in message and "Extra inputs are not permitted" in message


def test_environment_overrides_still_work_with_strict_keys(monkeypatch, tmp_path):
    config = tmp_path / "config.toml"
    config.write_text('cluster = "example"\n[slurm]\nuser_name = "monitor"\ntoken = "file"\n')
    monkeypatch.setenv("SLURM_MONITOR_CONFIG", str(config))
    monkeypatch.setenv("SLURM_MONITOR_SLURM__TOKEN", "from-environment")
    monkeypatch.setenv("SLURM_MONITOR_AUTH__STATIC__ENABLED", "true")
    monkeypatch.setenv("SLURM_MONITOR_AUTH__STATIC__TOKENS", '["env-token"]')
    monkeypatch.setenv("SLURM_MONITOR_POLL__INTERVAL_SECONDS", "30")
    monkeypatch.setenv("SLURM_MONITOR_CLUSTER", "from-environment")
    settings = load_settings()
    assert (settings.cluster, settings.slurm.token) == ("from-environment", "from-environment")
    assert settings.slurm.user_name == "monitor"
    assert settings.auth.static.enabled and settings.auth.static.tokens == ["env-token"]
    assert settings.poll.interval_seconds == 30
    # A misspelt override of a section's key fails as loudly as one in the file.
    monkeypatch.setenv("SLURM_MONITOR_SLURM__TOKN", "x")
    with pytest.raises(ValueError, match="slurm.tokn"):
        load_settings()


# ----- error answers -----------------------------------------------------------


async def test_every_error_answer_has_the_contract_shape(monkeypatch):
    harness = Harness()
    await harness.poll()
    async with harness.client() as client:
        cases = [
            (await client.get("/api/v1/nowhere"), 404, "not_found"),
            (await client.get("/"), 404, "not_found"),
            (await client.get("/metrics"), 404, "not_found"),
            (await client.post("/api/v1/queue"), 405, "method_not_allowed"),
            (await client.delete("/api/v1/health"), 405, "method_not_allowed"),
            (await client.get("/api/v1/queue", params={"user": "x" * 129}), 422, "invalid_request"),
            (await client.get("/api/v1/nodes?partition=" + "p" * 500), 422, "invalid_request"),
        ]  # fmt: skip
    for response, status, code in cases:
        assert response.status_code == status
        assert response.json() == {"error": code}

    def broken(*arguments, **keywords):
        raise RuntimeError("a defect")

    monkeypatch.setattr(QueueAggregator, "build", broken)
    transport = httpx.ASGITransport(app=harness.app, raise_app_exceptions=False)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://server",
        headers={"Authorization": f"Bearer {STATIC_TOKEN}"},
    ) as client:  # fmt: skip
        response = await client.get("/api/v1/queue")
    assert response.status_code == 500 and response.json() == {"error": "internal_error"}


def test_the_contract_lists_every_error_code():
    text = CONTRACT.read_text(encoding="utf-8")
    for line in (
        '401 {"error": "unauthorized"}', '403 {"error": "forbidden"}',
        '503 {"error": "no_data"}', '503 {"error": "auth_unavailable"}',
        '422 {"error": "invalid_request"}', '404 {"error": "not_found"}',
        '405 {"error": "method_not_allowed"}', '500 {"error": "internal_error"}',
    ):  # fmt: skip
        assert line in text, line


# ----- contract clarifications -------------------------------------------------


def job_payload(job_id: int, state: str, **values) -> dict:
    return {"job_id": job_id, "name": f"job{job_id}", "user_name": "u1", "partition": "gpu",
            "qos": "12h", "job_state": [state], "state_reason": "Priority",
            "submit_time": number(NOW - 100), **values}  # fmt: skip


def test_a_pending_job_array_counts_as_one_job():
    payload = {"jobs": [
        # Slurm keeps the waiting tasks of an array as one record …
        job_payload(500, "PENDING", array_job_id=number(500), array_task_id=number(0) | {
            "set": False}, array_task_string="7-99%4", array_max_tasks=number(4)),
        # … and gives every started task a record of its own.
        *(job_payload(501 + task, "RUNNING", array_job_id=number(500),
                      array_task_id=number(task), start_time=number(NOW - 50))
          for task in range(7)),
    ]}  # fmt: skip
    jobs = reduce_jobs(payload, CLASSIFIER)
    assert [job.state for job in jobs].count("PD") == 1
    state = ClusterState(polled_at=NOW, jobs=jobs, nodes=(), qos=(), shares=())
    queue = QueueAggregator(GpuSettings()).build(state, [], user="u1")
    assert (queue.pending, queue.running) == (1, 7)
    assert queue.mine.pending == 1 and queue.my_jobs_total == 8


def test_longest_gpu_wait_leaves_out_held_and_dependent_jobs():
    gpu = {"tres_per_node": "gres/gpu:a100:1"}
    waits = {
        "JobHeldUser": 90_000, "JobHeldAdmin": 80_000, "Dependency": 70_000,
        "DependencyNeverSatisfied": 60_000, "Priority": 500, "Resources": 1200,
        "QOSGrpGRES": 900,
    }  # fmt: skip
    payload = {"jobs": [
        job_payload(index, "PENDING", state_reason=reason, submit_time=number(NOW - wait), **gpu)
        for index, (reason, wait) in enumerate(waits.items(), start=1)
    ]}  # fmt: skip
    payload["jobs"].append(job_payload(50, "PENDING", submit_time=number(NOW - 99_000)))  # no GPU
    state = ClusterState(
        polled_at=NOW, jobs=reduce_jobs(payload, CLASSIFIER), nodes=(), qos=(), shares=()
    )
    result = GpuAggregator(GpuSettings()).build(state, [])
    # All seven count as pending; the wait is that of the oldest job that only
    # waits for resources, measured from its submission.
    assert (result.pending_jobs, result.longest_wait_seconds) == (7, 1200)

    only_held = ClusterState(
        polled_at=NOW, jobs=reduce_jobs({"jobs": payload["jobs"][:4]}, CLASSIFIER),
        nodes=(), qos=(), shares=(),
    )  # fmt: skip
    result = GpuAggregator(GpuSettings()).build(only_held, [])
    assert (result.pending_jobs, result.longest_wait_seconds) == (4, 0)


def test_history_has_at_most_one_point_per_five_minutes_and_gaps_after_failed_polls():
    store = HistoryStore()
    start = NOW // 300 * 300
    # Polls every minute for ten minutes, none for the next twenty, then two more.
    for second in [*range(0, 600, 60), 1800, 1860]:
        store.record(ClusterState(polled_at=start + second, jobs=(), nodes=(), qos=(), shares=()))
    stamps = [point.t - start for point in store.points()]
    assert stamps == [0, 300, 1800]


async def test_history_gap_reaches_the_api():
    harness = Harness()
    for minutes, failing in ((0, False), (5, True), (10, True), (15, False)):
        harness.clock.now = NOW + minutes * 60
        harness.slurmrestd.failing = failing
        assert await harness.poll() is not failing
    async with harness.client() as client:
        history = (await client.get("/api/v1/queue")).json()["data"]["history"]
    assert [point["t"] for point in history] == ["2026-10-01T12:30:00Z", "2026-10-01T12:45:00Z"]
