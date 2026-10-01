"""Reduction of slurmrestd payloads to compact records, in both JSON forms."""

import pytest

from slurm_monitor_server.config import RunnerSettings
from slurm_monitor_server.reduce import (
    RunnerClassifier,
    map_node_state,
    reduce_job,
    reduce_jobs,
    reduce_node,
    reduce_nodes,
    reduce_qos,
    reduce_shares,
)
from synthetic_cluster import CLUSTER, NOW

CLASSIFIER = RunnerClassifier(RunnerSettings())


@pytest.mark.parametrize(
    ("flags", "expected"),
    [
        (["IDLE"], "idle"),
        (["ALLOCATED"], "allocated"),
        (["MIXED"], "allocated"),
        (["IDLE", "COMPLETING"], "allocated"),
        (["IDLE", "DRAIN"], "drained"),
        (["ALLOCATED", "DRAIN"], "drained"),
        (["MIXED", "DRAINING"], "drained"),
        (["MIXED", "DRAINED"], "drained"),
        (["IDLE", "MAINT"], "drained"),
        # slurmrestd's own spelling of the maintenance flag
        (["IDLE", "MAINTENANCE"], "drained"),
        (["ALLOCATED", "MAINTENANCE"], "drained"),
        # a reservation only takes an idle node away; one in use is allocated
        (["IDLE", "RESERVED"], "drained"),
        (["ALLOCATED", "RESERVED"], "allocated"),
        (["MIXED", "RESERVED"], "allocated"),
        (["DOWN"], "down"),
        (["DOWN", "DRAIN"], "down"),
        (["DOWN", "MAINTENANCE", "RESERVED"], "down"),
        (["IDLE", "NOT_RESPONDING"], "down"),
        (["ALLOCATED", "FAIL"], "down"),
        (["ERROR"], "down"),
        (["IDLE", "INVALID_REG"], "down"),
        (["UNKNOWN"], "down"),
        # with power saving these nodes are available
        (["IDLE", "POWERED_DOWN"], "idle"),
        (["IDLE", "POWERING_UP"], "idle"),
        (["IDLE", "POWERING_DOWN"], "idle"),
        (["IDLE", "REBOOT_ISSUED"], "idle"),
        (["IDLE", "CLOUD"], "idle"),
        (["IDLE", "PLANNED"], "idle"),
        (["IDLE", "CLOUD", "POWERED_DOWN", "DRAIN"], "drained"),
        ([], "idle"),
    ],
)
def test_node_state_mapping(flags, expected):
    assert map_node_state(flags) == expected


def test_both_forms_reduce_to_the_same_jobs_and_nodes():
    wrapped_jobs = reduce_jobs(CLUSTER.jobs_payload(NOW, "wrapped"), CLASSIFIER)
    plain_jobs = reduce_jobs(CLUSTER.jobs_payload(NOW, "plain"), CLASSIFIER)
    assert wrapped_jobs == plain_jobs
    assert len(wrapped_jobs) > 400

    wrapped_nodes = reduce_nodes(
        CLUSTER.nodes_payload(NOW, "wrapped"), CLUSTER.partitions_payload(NOW, "wrapped")
    )
    plain_nodes = reduce_nodes(
        CLUSTER.nodes_payload(NOW, "plain"), CLUSTER.partitions_payload(NOW, "plain")
    )
    assert wrapped_nodes == plain_nodes
    assert len(wrapped_nodes) == 240

    assert reduce_qos(CLUSTER.qos_payload(NOW, "wrapped")) == reduce_qos(
        CLUSTER.qos_payload(NOW, "plain")
    )


def test_only_running_and_pending_jobs_are_kept():
    payload = CLUSTER.jobs_payload(NOW, "wrapped")
    states = {tuple(job["job_state"]) for job in payload["jobs"]}
    assert ("COMPLETED",) in states and ("TIMEOUT",) in states
    assert {job.state for job in reduce_jobs(payload, CLASSIFIER)} == {"R", "PD"}


def test_job_fields_in_newer_form():
    job = reduce_job(
        {
            "job_id": 42,
            "name": "train",
            "user_name": "someone",
            "account": "acc",
            "partition": "gpu",
            "qos": "12h",
            "job_state": ["RUNNING"],
            "state_reason": "None",
            "submit_time": {"set": True, "infinite": False, "number": 1000},
            "start_time": {"set": True, "infinite": False, "number": 2000},
            "time_limit": {"set": True, "infinite": False, "number": 90},
            "node_count": {"set": True, "infinite": False, "number": 2},
            "cpus": {"set": True, "infinite": False, "number": 16},
            "nodes": "gpu-[005-006]",
            "tres_per_node": "gres/gpu:a100:2",
            "gres_detail": ["gpu:a100:2(IDX:0-1)", "gpu:a100:2(IDX:2-3)"],
        },
        CLASSIFIER,
        "gpu",
    )
    assert job is not None
    assert (job.state, job.time_limit_seconds, job.node_count, job.cpus) == ("R", 5400, 2, 16)
    assert (job.submit_time, job.start_time) == (1000, 2000)
    assert (job.gpu_count, job.gpu_type) == (4, "a100")
    assert job.gpu_cards == (("gpu-005", 0), ("gpu-005", 1), ("gpu-006", 2), ("gpu-006", 3))


def test_job_fields_in_older_form_and_unlimited_time():
    job = reduce_job(
        {
            "job_id": 43,
            "name": "wait",
            "user_name": "someone",
            "partition": "gpu",
            "qos": "12h",
            "job_state": "PENDING",
            "state_reason": "Priority",
            "submit_time": 1000,
            "start_time": 0,
            "time_limit": 0xFFFFFFFF,
            "node_count": 2,
            "cpus": 16,
            "nodes": "",
            "tres_per_node": "gpu:a40:1",
            "tres_req_str": "cpu=16,node=2",
        },
        CLASSIFIER,
        "gpu",
    )
    assert job is not None
    assert (job.state, job.time_limit_seconds, job.start_time) == ("PD", None, None)
    # One card per node on two nodes.
    assert (job.gpu_count, job.gpu_type, job.gpu_cards) == (2, "a40", ())


def test_pending_gpu_count_prefers_the_tres_request_total():
    job = reduce_job(
        {
            "job_id": 1,
            "job_state": ["PENDING"],
            "node_count": 1,
            "tres_req_str": "cpu=8,gres/gpu=3,gres/gpu:a100=3",
        },  # fmt: skip
        CLASSIFIER,
        "gpu",
    )
    assert job is not None and (job.gpu_count, job.gpu_type) == (3, "a100")


def test_running_gpu_job_without_gres_detail_degrades_to_a_count():
    job = reduce_job(
        {
            "job_id": 1,
            "job_state": "RUNNING",
            "nodes": "gpu-001",
            "tres_alloc_str": "cpu=8,gres/gpu=2",
        },  # fmt: skip
        CLASSIFIER,
        "gpu",
    )
    assert job is not None and (job.gpu_count, job.gpu_cards) == (2, ())


def test_runner_classification():
    def kind(name, command="", comment=""):
        job = reduce_job(
            {
                "job_id": 1,
                "job_state": "RUNNING",
                "name": name,
                "command": command,
                "comment": comment,
            },  # fmt: skip
            CLASSIFIER,
            "gpu",
        )
        assert job is not None
        return job.runner_kind, job.is_dask_scheduler, job.dask_cluster

    assert kind("ci-12345") == ("ci", False, "")
    assert kind("ci-abc") == (None, False, "")
    assert kind("dask-gateway", "/x/dask-worker", "a3f1") == ("dask", False, "a3f1")
    assert kind("dask-gateway", "/x/dask-scheduler", "a3f1") == ("dask", True, "a3f1")
    assert kind("dask-gateway-scheduler") == ("dask", True, "")
    assert kind("spawner-jupyterhub") == ("jupyterhub", False, "")
    assert kind("jupyterhub-singleuser") == ("jupyterhub", False, "")
    assert kind("my-scheduler-test", "scheduler") == (None, False, "")


def test_node_gpu_allocation_from_idx_list():
    node = reduce_node(
        {
            "name": "gpu-005",
            "state": ["MIXED"],
            "partitions": ["gpu"],
            "gres": "gpu:a100:4(S:0-1)",
            "gres_used": "gpu:a100:2(IDX:1,3)",
        },  # fmt: skip
        {},
        "gpu",
    )
    assert node is not None
    assert node.gpu_types == ("a100",) * 4
    assert node.gpu_allocated == frozenset({1, 3})


def test_node_gpu_allocation_without_idx_marks_the_first_cards():
    node = reduce_node(
        {
            "name": "gpu-005",
            "state": "mixed",
            "partitions": "gpu",
            "gres": "gpu:a100:4",
            "gres_used": "gpu:a100:3",
        },  # fmt: skip
        {},
        "gpu",
    )
    assert node is not None
    assert node.gpu_allocated == frozenset({0, 1, 2})
    assert node.partitions == ("gpu",)


def test_node_with_two_gpu_types_and_untyped_gres():
    node = reduce_node(
        {
            "name": "n1",
            "state": ["IDLE"],
            "gres": "gpu:a40:1,gpu:a100:2",
            "gres_used": "gpu:a40:0(IDX:N/A),gpu:a100:1(IDX:2)",
        },  # fmt: skip
        {},
        "gpu",
    )
    assert node is not None
    assert node.gpu_types == ("a40", "a100", "a100")
    assert node.gpu_allocated == frozenset({2})
    untyped = reduce_node({"name": "n2", "state": ["IDLE"], "gres": "gpu:2"}, {}, "gpu")
    assert untyped is not None and untyped.gpu_types == ("gpu", "gpu")


@pytest.mark.parametrize("form", ["wrapped", "plain"])
def test_partitions_endpoint_fills_in_missing_node_partitions(form):
    nodes_payload = CLUSTER.nodes_payload(NOW, form)
    for node in nodes_payload["nodes"]:
        del node["partitions"]
    nodes = reduce_nodes(nodes_payload, CLUSTER.partitions_payload(NOW, form))
    by_name = {node.name: node for node in nodes}
    assert by_name["prod-001"].partitions == ("mpp",)
    assert set(by_name["fat-001"].partitions) == {"fat", "smp"}


def test_qos_limits():
    by_name = {record.name: record for record in reduce_qos(CLUSTER.qos_payload(NOW, "wrapped"))}
    assert (by_name["12h"].cpu_limit, by_name["12h"].max_wall_seconds) == (18000, 43200)
    assert (by_name["30min"].cpu_limit, by_name["30min"].max_wall_seconds) == (None, 1800)
    assert (by_name["unused"].cpu_limit, by_name["unused"].max_wall_seconds) == (None, None)
    assert reduce_qos(None) == ()
    assert reduce_qos({"qos": [{"name": "bare"}]})[0].cpu_limit is None


def test_shares_keep_user_rows_only_and_accept_both_factor_forms():
    shares = reduce_shares(CLUSTER.shares_payload(NOW, "wrapped"))
    by_user = {share.user: share for share in shares}
    assert "root" not in by_user and "hpc" not in by_user
    assert (by_user["alice"].account, by_user["alice"].fairshare) == ("hpc", 0.42)

    newer = {"shares": {"shares": [
        {"name": "u", "parent": "a", "type": ["USER"],
         "fairshare": {"factor": {"set": True, "infinite": False, "number": 0.3}}},
    ]}}  # fmt: skip
    assert reduce_shares(newer)[0].fairshare == 0.3
    assert reduce_shares(None) == ()
    assert reduce_shares({"shares": []}) == ()
