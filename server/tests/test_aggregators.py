"""Each aggregator against the rules of docs/contract.md."""

from __future__ import annotations

from typing import Any

from slurm_monitor_server.aggregators import (
    GpuAggregator,
    NodesAggregator,
    QosAggregator,
    QueueAggregator,
    RunnersAggregator,
    normalise_reason,
)
from slurm_monitor_server.config import GpuSettings, RunnerSettings
from slurm_monitor_server.history import HistoryStore
from slurm_monitor_server.records import (
    CardMetrics,
    ClusterState,
    JobRecord,
    NodeRecord,
    QosRecord,
    ShareRecord,
)

NOW = 1_790_000_000
GPU_SETTINGS = GpuSettings(labels={"a100": "A100", "a40": "A40"})


def job(job_id: int, state: str = "R", **values: Any) -> JobRecord:
    defaults: dict[str, Any] = {
        "name": f"job{job_id}", "user": "u1", "account": "acc", "partition": "mpp", "qos": "12h",
        "reason": "None" if state == "R" else "Priority", "submit_time": NOW - 1000,
        "start_time": NOW - 600 if state == "R" else None, "time_limit_seconds": 3600,
        "node_count": 1, "cpus": 4, "gpu_count": 0, "gpu_type": "", "gpu_cards": (),
        "runner_kind": None, "is_dask_scheduler": False, "dask_cluster": "",
    }  # fmt: skip
    defaults.update(values)
    return JobRecord(job_id=job_id, state=state, **defaults)


def node(name: str, state: str = "idle", partitions=("mpp",), gpu_types=(), allocated=()):
    return NodeRecord(name, state, tuple(partitions), tuple(gpu_types), frozenset(allocated))


def cluster(jobs=(), nodes=(), **values: Any) -> ClusterState:
    return ClusterState(
        polled_at=NOW, jobs=tuple(jobs), nodes=tuple(nodes),
        qos=values.pop("qos", ()), shares=values.pop("shares", ()), **values,
    )  # fmt: skip


# ----- queue -----------------------------------------------------------------


def test_reason_normalisation():
    assert normalise_reason("Priority") == "Priority"
    assert normalise_reason("Resources") == "Resources"
    assert normalise_reason("QOSGrpCpuLimit") == "QOS limit"
    assert normalise_reason("QOSMaxJobsPerUserLimit") == "QOS limit"
    assert normalise_reason("AssocGrpCpuLimit") == "QOS limit"
    assert normalise_reason("Dependency") == "Dependency"
    assert normalise_reason("JobHeldUser") == "Held"
    assert normalise_reason("JobHeldAdmin") == "Held"
    assert normalise_reason("BeginTime") == "Other"
    assert normalise_reason("None") == "Other"


def test_queue_counts_and_reasons_sorted_without_zero_entries():
    jobs = [job(1), job(2)]
    jobs += [job(10 + i, "PD", reason="Resources") for i in range(3)]
    jobs += [job(20 + i, "PD", reason="QOSGrpCpuLimit") for i in range(2)]
    jobs += [job(30, "PD", reason="AssocGrpCpuLimit"), job(31, "PD", reason="Priority")]
    queue = QueueAggregator(GPU_SETTINGS).build(cluster(jobs), [])
    assert (queue.running, queue.pending) == (2, 7)
    assert [(e.reason, e.count) for e in queue.pending_by_reason] == [
        ("Resources", 3), ("QOS limit", 3), ("Priority", 1),
    ]  # fmt: skip
    assert queue.mine is None and queue.my_jobs == [] and queue.my_jobs_total == 0
    assert queue.user is None


def test_queue_reasons_hold_at_most_six_entries():
    reasons = ["Priority", "Resources", "QOSMaxWall", "Dependency", "JobHeldUser", "BeginTime",
               "ReqNodeNotAvail", "Licenses"]  # fmt: skip
    jobs = [job(i, "PD", reason=reason) for i, reason in enumerate(reasons)]
    queue = QueueAggregator(GPU_SETTINGS).build(cluster(jobs), [])
    assert len(queue.pending_by_reason) == 6
    assert queue.pending_by_reason[0].reason == "Other"
    assert sum(entry.count for entry in queue.pending_by_reason) == 8


def test_my_jobs_order_states_and_fields():
    jobs = [
        job(1, start_time=NOW - 100),
        job(2, start_time=NOW - 900, time_limit_seconds=None),
        job(3, "PD", start_time=NOW + 500, reason="Resources"),
        job(4, "PD", start_time=None, reason="JobHeldUser"),
        job(5, "PD", start_time=NOW + 60),
        job(6, user="other"),
    ]
    queue = QueueAggregator(GPU_SETTINGS).build(cluster(jobs), [], user="u1")
    assert [entry.job_id for entry in queue.my_jobs] == [2, 1, 5, 3, 4]
    assert queue.mine is not None
    assert (queue.mine.running, queue.mine.pending, queue.my_jobs_total) == (2, 3, 5)
    first, pending, held = queue.my_jobs[0], queue.my_jobs[2], queue.my_jobs[4]
    assert (first.state, first.elapsed_seconds, first.time_limit_seconds) == ("R", 900, None)
    assert (first.estimated_start, first.reason) == (None, None)
    assert (pending.state, pending.elapsed_seconds) == ("PD", 0)
    assert pending.estimated_start == "2026-09-21T14:14:20Z"
    assert (held.estimated_start, held.reason) == (None, "Held")


def test_my_jobs_capped_at_twenty_with_full_total():
    jobs = [job(i, start_time=NOW - i) for i in range(1, 26)]
    jobs += [job(100 + i, "PD") for i in range(5)]
    queue = QueueAggregator(GPU_SETTINGS).build(cluster(jobs), [], user="u1")
    assert len(queue.my_jobs) == 20
    assert queue.my_jobs_total == 30
    assert all(entry.state == "R" for entry in queue.my_jobs)


def test_resources_string():
    aggregator = QueueAggregator(GPU_SETTINGS)
    assert aggregator.resources(job(1, node_count=16, cpus=2048)) == "16 nodes"
    assert aggregator.resources(job(1, node_count=1, cpus=64)) == "64 cores"
    assert aggregator.resources(job(1, node_count=1, cpus=1)) == "1 core"
    assert aggregator.resources(job(1, node_count=1, cpus=0)) == "1 node"
    assert aggregator.resources(job(1, gpu_count=2, gpu_type="a100")) == "2 A100"
    assert aggregator.resources(job(1, gpu_count=1, gpu_type="")) == "1 GPU"
    assert aggregator.resources(job(1, gpu_count=1, gpu_type="h100")) == "1 H100"


def test_queue_filters_and_history_follow_partition_and_qos():
    jobs = [
        job(1, partition="mpp", qos="12h"),
        job(2, partition="smp", qos="12h"),
        job(3, "PD", partition="smp,fat", qos="48h"),
        job(4, "PD", partition="mpp", qos="48h"),
    ]
    state = cluster(jobs)
    history = HistoryStore()
    history.record(state)
    aggregator = QueueAggregator(GPU_SETTINGS)

    everything = aggregator.build(state, history.points())
    assert (everything.running, everything.pending) == (2, 2)
    assert (everything.history[0].running, everything.history[0].pending) == (2, 2)

    fat = aggregator.build(state, history.points(), partition="fat")
    assert (fat.partition, fat.running, fat.pending) == ("fat", 0, 1)
    assert (fat.history[0].running, fat.history[0].pending) == (0, 1)

    long_smp = aggregator.build(state, history.points(), partition="smp", qos="48h")
    assert (long_smp.qos, long_smp.running, long_smp.pending) == ("48h", 0, 1)

    mine = aggregator.build(state, history.points(), partition="mpp", user="u1")
    assert mine.mine is not None and (mine.mine.running, mine.mine.pending) == (1, 1)


def test_history_is_one_point_per_five_minutes_and_at_most_72():
    store = HistoryStore()
    for step in range(100 * 5):  # one poll a minute for 500 minutes
        state = ClusterState(NOW + step * 60, (job(1),), (), (), ())
        store.record(state)
    points = store.points()
    assert len(points) == 72
    assert all(b.t - a.t == 300 for a, b in zip(points, points[1:], strict=False))
    assert all(point.t % 300 == 0 for point in points)
    assert HistoryStore(window_seconds=3600)._max_points == 12


# ----- nodes -----------------------------------------------------------------


def test_nodes_counts_are_over_unique_nodes_and_sorted():
    nodes = [
        node("b-2", "allocated", ("big",)),
        node("b-1", "idle", ("big",)),
        node("b-3", "down", ("big", "small")),
        node("s-1", "drained", ("small",)),
    ]
    result = NodesAggregator().build(cluster(nodes=nodes))
    assert (result.total, result.allocated, result.idle, result.drained, result.down) == (
        4, 1, 1, 1, 1,
    )  # fmt: skip
    assert [partition.name for partition in result.partitions] == ["big", "small"]
    big, small = result.partitions
    assert [entry.name for entry in big.nodes] == ["b-1", "b-2", "b-3"]
    assert (big.total, big.down) == (3, 1)
    assert [entry.name for entry in small.nodes] == ["b-3", "s-1"]
    assert sum(partition.total for partition in result.partitions) == 5


def test_nodes_partition_filter():
    nodes = [node("a", "allocated", ("p", "q")), node("b", "idle", ("p",))]
    result = NodesAggregator().build(cluster(nodes=nodes), partition="q")
    assert (result.total, result.allocated, result.idle) == (1, 1, 0)
    assert [partition.name for partition in result.partitions] == ["q"]
    unknown = NodesAggregator().build(cluster(nodes=nodes), partition="nope")
    assert (unknown.total, unknown.partitions) == (0, [])


# ----- qos -------------------------------------------------------------------


def test_qos_listing_rules():
    jobs = [
        job(1, qos="a", cpus=10),
        job(2, qos="a", cpus=20),
        job(3, "PD", qos="a", cpus=99),
        job(4, qos="b", cpus=100),
        job(5, "PD", qos="unknown-to-slurmdb"),
    ]
    qos = (
        QosRecord("a", 1000, 43200),
        QosRecord("b", None, None),
        QosRecord("limit-only", 500, None),
        QosRecord("idle-unlimited", None, 3600),
    )
    result = QosAggregator().build(cluster(jobs, qos=qos))
    assert [entry.name for entry in result.qos] == ["b", "a", "limit-only", "unknown-to-slurmdb"]
    a = result.qos[1]
    assert (a.cpus_in_use, a.cpu_limit, a.running_jobs, a.pending_jobs) == (30, 1000, 2, 1)
    assert a.max_wall_seconds == 43200
    assert (result.user, result.account, result.fairshare) == (None, None, None)


def test_qos_account_and_fairshare():
    shares = (ShareRecord("u1", "acc", 0.42), ShareRecord("u2", "x", None))
    state = cluster([job(1)], shares=shares)
    result = QosAggregator().build(state, "u1")
    assert (result.user, result.account, result.fairshare) == ("u1", "acc", 0.42)
    assert QosAggregator().build(state, "u2").fairshare is None
    # Without share rows the account is taken from the user's jobs.
    result = QosAggregator().build(cluster([job(1)]), "u1")
    assert (result.account, result.fairshare) == ("acc", None)
    result = QosAggregator().build(cluster([job(1)]), "stranger")
    assert (result.account, result.fairshare) == (None, None)


def test_qos_picks_the_account_the_user_is_running_in():
    shares = (ShareRecord("u1", "aaa", 0.1), ShareRecord("u1", "acc", 0.9))
    result = QosAggregator().build(cluster([job(1)], shares=shares), "u1")
    assert (result.account, result.fairshare) == ("acc", 0.9)


# ----- gpu -------------------------------------------------------------------


def gpu_cluster(metrics_available: bool, metrics=None) -> ClusterState:
    nodes = [
        node("g-1", "allocated", ("gpu",), ["a40", "a40"], [0]),
        node("g-2", "allocated", ("gpu",), ["a100"] * 4, [0, 1, 2]),
        node("g-3", "drained", ("gpu",), ["a100"] * 4, [3]),
        node("g-4", "down", ("gpu",), ["a40", "a40"], []),
        node("c-1", "idle"),
    ]
    jobs = [
        job(1, user="u1", gpu_count=2, gpu_type="a100", gpu_cards=(("g-2", 0), ("g-2", 1))),
        job(2, user="u2", gpu_count=1, gpu_type="a100", gpu_cards=()),
        job(3, user="u3", gpu_count=1, gpu_type="a40", gpu_cards=(("g-1", 0),)),
        job(4, "PD", gpu_count=1, gpu_type="a40", submit_time=NOW - 500),
        job(5, "PD", gpu_count=4, gpu_type="a100", submit_time=NOW - 7000),
        job(6, "PD", submit_time=NOW - 99999),
    ]
    return cluster(jobs, nodes, metrics_available=metrics_available, gpu_metrics=metrics or {})


def test_gpu_without_metrics():
    state = gpu_cluster(False)
    history = HistoryStore()
    history.record(state)
    gpu = GpuAggregator(GPU_SETTINGS).build(state, history.points())
    assert gpu.metrics_available is False
    assert (gpu.total, gpu.allocated, gpu.idle_allocated) == (12, 5, None)
    assert (gpu.pending_jobs, gpu.longest_wait_seconds) == (2, 7000)
    assert [(t.type, t.label, t.total, t.allocated) for t in gpu.types] == [
        ("a100", "A100", 8, 4), ("a40", "A40", 4, 1),
    ]  # fmt: skip
    assert [n.name for n in gpu.nodes] == ["g-2", "g-3", "g-1", "g-4"]
    states = {n.name: [card.state for card in n.cards] for n in gpu.nodes}
    assert states["g-2"] == ["allocated", "allocated", "allocated", "free"]
    assert states["g-3"] == ["drained", "drained", "drained", "allocated"]
    assert states["g-4"] == ["down", "down"]
    assert states["g-1"] == ["allocated", "free"]
    cards = [card for n in gpu.nodes for card in n.cards]
    assert all(card.utilisation is None and card.power_w is None for card in cards)
    assert all(card.state not in ("busy", "idle_allocated") for card in cards)
    assert gpu.history[0].utilisation is None
    assert gpu.history[0].allocated_fraction == 0.417
    by_node = {n.name: n for n in gpu.nodes}
    assert [card.user for card in by_node["g-2"].cards] == ["u1", "u1", None, None]
    assert (by_node["g-3"].state, by_node["g-3"].type) == ("drained", "a100")


def test_gpu_with_metrics():
    metrics = {
        ("g-2", 0): CardMetrics(0.97, 36864, 40960, 74, 286),
        ("g-2", 1): CardMetrics(0.05, 100, 40960, 40, 60),
        ("g-2", 2): CardMetrics(0.049, 100, 40960, 40, 60),
        ("g-2", 3): CardMetrics(0.0, 3, 40960, 30, 50),
        ("g-3", 3): CardMetrics(0.0, 3, 40960, 30, 50),
    }
    state = gpu_cluster(True, metrics)
    history = HistoryStore()
    history.record(state)
    gpu = GpuAggregator(GPU_SETTINGS).build(state, history.points())
    by_node = {n.name: n for n in gpu.nodes}
    assert [card.state for card in by_node["g-2"].cards] == [
        "busy", "busy", "idle_allocated", "free",
    ]  # fmt: skip
    assert by_node["g-3"].cards[3].state == "idle_allocated"
    # An allocated card the source said nothing about stays plain "allocated".
    assert by_node["g-1"].cards[0].state == "allocated"
    assert gpu.idle_allocated == 2
    card = by_node["g-2"].cards[0]
    assert (card.utilisation, card.memory_used_mib, card.memory_total_mib) == (0.97, 36864, 40960)
    assert (card.temperature_c, card.power_w, card.user) == (74, 286, "u1")
    # Mean over the allocated cards that report: (0.97 + 0.05 + 0.049 + 0.0) / 4.
    assert gpu.history[0].utilisation == 0.267


def test_gpu_top_users_sorted_and_capped():
    jobs = [job(i, user=f"u{i}", gpu_count=i, gpu_type="a100") for i in range(1, 8)]
    jobs.append(job(20, user="u7", gpu_count=1, gpu_type="a100"))
    jobs.append(job(21, "PD", user="u1", gpu_count=50))
    gpu = GpuAggregator(GPU_SETTINGS).build(cluster(jobs), [])
    assert [(entry.user, entry.cards) for entry in gpu.top_users] == [
        ("u7", 8), ("u6", 6), ("u5", 5), ("u4", 4), ("u3", 3),
    ]  # fmt: skip
    assert (gpu.total, gpu.longest_wait_seconds) == (0, 1000)


def test_gpu_longest_wait_is_zero_without_pending_gpu_jobs():
    gpu = GpuAggregator(GPU_SETTINGS).build(cluster([job(1)]), [])
    assert (gpu.pending_jobs, gpu.longest_wait_seconds) == (0, 0)


# ----- runners ---------------------------------------------------------------

RUNNER_SETTINGS = RunnerSettings(extra=[{"key": "matlab", "label": "MATLAB", "pattern": "^matlab"}])


def test_ci_runners():
    jobs = [
        job(1, runner_kind="ci"),
        job(2, runner_kind="ci"),
        job(3, "PD", runner_kind="ci", submit_time=NOW - 1080),
        job(4, "PD", runner_kind="ci", submit_time=NOW - 30),
        job(5, "PD", submit_time=NOW - 99999),
    ]
    ci = RunnersAggregator(RUNNER_SETTINGS).build(cluster(jobs)).ci
    assert (ci.runners_alive, ci.jobs_waiting, ci.oldest_wait_seconds) == (2, 2, 1080)
    empty = RunnersAggregator(RUNNER_SETTINGS).build(cluster([job(1)])).ci
    assert (empty.runners_alive, empty.jobs_waiting, empty.oldest_wait_seconds) == (0, 0, None)


def dask(job_id, state="R", scheduler=False, cluster_id="c1", user="u1", **values):
    return job(job_id, state, runner_kind="dask", is_dask_scheduler=scheduler,
               dask_cluster=cluster_id, user=user, **values)  # fmt: skip


def test_dask_clusters():
    jobs = [
        dask(1, scheduler=True),
        dask(2, start_time=NOW - 1000, time_limit_seconds=3600),
        dask(3, start_time=NOW - 3000, time_limit_seconds=3600),
        dask(4, "PD"),
        # No comment: grouped by owner; scheduler not running; no worker runs.
        dask(10, "PD", scheduler=True, cluster_id="", user="u0"),
        dask(11, "PD", cluster_id="", user="u0"),
        dask(20, scheduler=True, cluster_id="b", user="u1"),
    ]
    clusters = RunnersAggregator(RUNNER_SETTINGS).build(cluster(jobs)).dask.clusters
    assert [(c.owner, c.id) for c in clusters] == [("u0", "u0"), ("u1", "b"), ("u1", "c1")]
    waiting, bare, full = clusters
    assert (waiting.scheduler_alive, waiting.workers_running, waiting.workers_requested) == (
        False, 0, 1,
    )  # fmt: skip
    assert waiting.walltime_left_seconds is None
    assert (bare.workers_requested, bare.walltime_left_seconds) == (0, None)
    assert (full.scheduler_alive, full.workers_running, full.workers_requested) == (True, 2, 3)
    assert full.walltime_left_seconds == 600

    mine = RunnersAggregator(RUNNER_SETTINGS).build(cluster(jobs), user="u0").dask.clusters
    assert [c.id for c in mine] == ["u0"]


def test_dask_clusters_capped_at_ten():
    jobs = [dask(i, scheduler=True, cluster_id=f"c{i:02d}") for i in range(14)]
    clusters = RunnersAggregator(RUNNER_SETTINGS).build(cluster(jobs)).dask.clusters
    assert [c.id for c in clusters] == [f"c{i:02d}" for i in range(10)]


def test_jupyterhub_and_extra():
    def hub(job_id, left, **values):
        return job(job_id, runner_kind="jupyterhub", time_limit_seconds=3600,
                   start_time=NOW - (3600 - left), **values)  # fmt: skip

    jobs = [
        hub(1, 899),
        hub(2, 900),
        hub(3, 10, gpu_count=1, gpu_type="a40"),
        job(4, runner_kind="jupyterhub", time_limit_seconds=None),
        job(5, "PD", runner_kind="jupyterhub"),
        job(6, runner_kind="extra:matlab"),
        job(7, "PD", runner_kind="extra:matlab"),
    ]
    result = RunnersAggregator(RUNNER_SETTINGS).build(cluster(jobs))
    hub_result = result.jupyterhub
    assert (hub_result.sessions, hub_result.with_gpu, hub_result.near_walltime) == (4, 1, 2)
    assert [(e.key, e.label, e.running, e.pending) for e in result.extra] == [
        ("matlab", "MATLAB", 1, 1)
    ]
    assert RunnersAggregator(RunnerSettings()).build(cluster(jobs)).extra == []
