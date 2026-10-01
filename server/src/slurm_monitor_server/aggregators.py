"""Aggregators: compact records → the five widget families of the contract."""

from __future__ import annotations

from collections import Counter
from datetime import UTC, datetime

from .config import GpuSettings, RunnerSettings
from .history import HistoryPoint
from .models import (
    CiRunners,
    DaskCluster,
    DaskRunners,
    ExtraRunners,
    Gpu,
    GpuCard,
    GpuHistoryPoint,
    GpuNode,
    GpuType,
    GpuUser,
    JupyterHubRunners,
    MineCounts,
    MyJob,
    NodeEntry,
    Nodes,
    PartitionNodes,
    Qos,
    QosEntry,
    Queue,
    QueueHistoryPoint,
    ReasonCount,
    Runners,
)
from .records import ClusterState, JobRecord, NodeRecord

MY_JOBS_LIMIT = 20
TOP_USERS_LIMIT = 5
DASK_CLUSTERS_LIMIT = 10
NEAR_WALLTIME_SECONDS = 15 * 60
IDLE_UTILISATION_THRESHOLD = 0.05
REASON_ORDER = ("Priority", "Resources", "QOS limit", "Dependency", "Held", "Other")


def iso_timestamp(unix_seconds: int) -> str:
    """ISO 8601, UTC, whole seconds, 'Z' suffix."""
    return datetime.fromtimestamp(int(unix_seconds), tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalise_reason(reason: str) -> str:
    if reason in ("Priority", "Resources", "Dependency"):
        return reason
    if reason.startswith(("QOS", "Assoc")):
        return "QOS limit"
    if reason in ("JobHeldUser", "JobHeldAdmin"):
        return "Held"
    return "Other"


def remaining_seconds(job: JobRecord, now: int) -> int | None:
    """Wall time left of a running job; None when the limit is unlimited or unknown."""
    if job.time_limit_seconds is None or job.start_time is None:
        return None
    return max(0, job.time_limit_seconds - max(0, now - job.start_time))


def wait_seconds(job: JobRecord, now: int) -> int:
    return max(0, now - job.submit_time) if job.submit_time is not None else 0


class QueueAggregator:
    def __init__(self, gpu: GpuSettings) -> None:
        self._gpu = gpu

    def resources(self, job: JobRecord) -> str:
        if job.gpu_count > 0:
            return f"{job.gpu_count} {gpu_label(self._gpu, job.gpu_type or self._gpu.gres_name)}"
        if job.node_count > 1 or job.cpus <= 0:
            count = max(job.node_count, 1)
            return f"{count} node" if count == 1 else f"{count} nodes"
        return f"{job.cpus} core" if job.cpus == 1 else f"{job.cpus} cores"

    def build(
        self,
        state: ClusterState,
        history: list[HistoryPoint],
        partition: str | None = None,
        qos: str | None = None,
        user: str | None = None,
    ) -> Queue:
        now = state.polled_at
        jobs = [
            job
            for job in state.jobs
            if (partition is None or job.in_partition(partition))
            and (qos is None or job.qos == qos)
        ]
        running = sum(1 for job in jobs if job.state == "R")
        pending = len(jobs) - running

        reasons = Counter(normalise_reason(job.reason) for job in jobs if job.state == "PD")
        by_reason = sorted(
            (ReasonCount(reason=reason, count=count) for reason, count in reasons.items() if count),
            key=lambda entry: (-entry.count, REASON_ORDER.index(entry.reason)),
        )[: len(REASON_ORDER)]

        mine: MineCounts | None = None
        my_jobs: list[MyJob] = []
        my_total = 0
        if user:
            own = [job for job in jobs if job.user == user]
            own_running = sorted(
                (job for job in own if job.state == "R"),
                key=lambda job: (-self._elapsed(job, now), job.job_id),
            )
            own_pending = sorted(
                (job for job in own if job.state == "PD"),
                key=lambda job: (
                    job.start_time is None,
                    job.start_time or 0,
                    job.job_id,
                ),
            )
            mine = MineCounts(running=len(own_running), pending=len(own_pending))
            my_total = len(own)
            for job in (own_running + own_pending)[:MY_JOBS_LIMIT]:
                is_pending = job.state == "PD"
                my_jobs.append(
                    MyJob(
                        job_id=job.job_id,
                        name=job.name,
                        state="PD" if is_pending else "R",
                        partition=job.partition,
                        resources=self.resources(job),
                        elapsed_seconds=0 if is_pending else self._elapsed(job, now),
                        time_limit_seconds=job.time_limit_seconds,
                        estimated_start=iso_timestamp(job.start_time)
                        if is_pending and job.start_time is not None
                        else None,
                        reason=normalise_reason(job.reason) if is_pending else None,
                    )
                )

        return Queue(
            partition=partition,
            qos=qos,
            user=user or None,
            running=running,
            pending=pending,
            mine=mine,
            pending_by_reason=by_reason,
            my_jobs_total=my_total,
            my_jobs=my_jobs,
            history=[self._history_point(point, partition, qos) for point in history],
        )

    @staticmethod
    def _elapsed(job: JobRecord, now: int) -> int:
        return max(0, now - job.start_time) if job.start_time is not None else 0

    @staticmethod
    def _history_point(
        point: HistoryPoint, partition: str | None, qos: str | None
    ) -> QueueHistoryPoint:
        running = pending = 0
        for (job_partition, job_qos), (r, p) in point.queue_counts.items():
            if partition is not None and partition not in job_partition.split(","):
                continue
            if qos is not None and job_qos != qos:
                continue
            running += r
            pending += p
        return QueueHistoryPoint(t=iso_timestamp(point.t), running=running, pending=pending)


class NodesAggregator:
    @staticmethod
    def _counts(nodes: list[NodeRecord]) -> dict[str, int]:
        states = Counter(node.state for node in nodes)
        return {
            "total": len(nodes),
            "allocated": states["allocated"],
            "idle": states["idle"],
            "drained": states["drained"],
            "down": states["down"],
        }

    def build(self, state: ClusterState, partition: str | None = None) -> Nodes:
        by_partition: dict[str, list[NodeRecord]] = {}
        for node in state.nodes:
            for name in node.partitions:
                by_partition.setdefault(name, []).append(node)
        if partition is not None:
            by_partition = {
                name: nodes for name, nodes in by_partition.items() if name == partition
            }
            unique = by_partition.get(partition, [])
        else:
            unique = list(state.nodes)

        partitions = [
            PartitionNodes(
                name=name,
                **self._counts(nodes),
                nodes=[
                    NodeEntry(name=node.name, state=node.state)  # type: ignore[arg-type]
                    for node in sorted(nodes, key=lambda node: node.name)
                ],
            )
            for name, nodes in by_partition.items()
        ]
        partitions.sort(key=lambda entry: (-entry.total, entry.name))
        return Nodes(**self._counts(unique), partitions=partitions)


class QosAggregator:
    def build(self, state: ClusterState, user: str | None = None) -> Qos:
        cpus: Counter[str] = Counter()
        running: Counter[str] = Counter()
        pending: Counter[str] = Counter()
        for job in state.jobs:
            if job.state == "R":
                running[job.qos] += 1
                cpus[job.qos] += job.cpus
            else:
                pending[job.qos] += 1

        known = {record.name: record for record in state.qos}
        names = set(known) | {name for name in (*running, *pending) if name}
        entries: list[QosEntry] = []
        for name in names:
            record = known.get(name)
            cpu_limit = record.cpu_limit if record else None
            if running[name] + pending[name] == 0 and cpu_limit is None:
                continue
            entries.append(
                QosEntry(
                    name=name,
                    cpus_in_use=cpus[name],
                    cpu_limit=cpu_limit,
                    running_jobs=running[name],
                    pending_jobs=pending[name],
                    max_wall_seconds=record.max_wall_seconds if record else None,
                )
            )
        entries.sort(key=lambda entry: (-entry.cpus_in_use, entry.name))

        account, fairshare = self._association(state, user) if user else (None, None)
        return Qos(user=user or None, account=account, fairshare=fairshare, qos=entries)

    @staticmethod
    def _association(state: ClusterState, user: str) -> tuple[str | None, float | None]:
        """Account and fairshare of a user; with several accounts, the one most used now."""
        job_accounts = Counter(
            job.account for job in state.jobs if job.user == user and job.account
        )
        shares = [share for share in state.shares if share.user == user]
        if shares:
            shares.sort(key=lambda share: (-job_accounts[share.account], share.account))
            chosen = shares[0]
            fairshare = round(chosen.fairshare, 4) if chosen.fairshare is not None else None
            return chosen.account or None, fairshare
        if job_accounts:
            return job_accounts.most_common(1)[0][0], None
        return None, None


def gpu_label(settings: GpuSettings, gpu_type: str) -> str:
    return settings.labels.get(gpu_type, gpu_type.upper())


class GpuAggregator:
    def __init__(self, settings: GpuSettings) -> None:
        self._settings = settings

    def build(self, state: ClusterState, history: list[HistoryPoint]) -> Gpu:
        now = state.polled_at
        with_metrics = state.metrics_available
        gpu_nodes = [node for node in state.nodes if node.gpu_types]

        card_user: dict[tuple[str, int], str] = {}
        user_cards: Counter[str] = Counter()
        for job in state.jobs:
            if job.state != "R" or job.gpu_count <= 0:
                continue
            user_cards[job.user] += job.gpu_count
            for card in job.gpu_cards:
                card_user[card] = job.user

        type_total: Counter[str] = Counter()
        type_allocated: Counter[str] = Counter()
        idle_allocated = 0
        nodes: list[GpuNode] = []
        for node in gpu_nodes:
            cards: list[GpuCard] = []
            for index, card_type in enumerate(node.gpu_types):
                allocated = index in node.gpu_allocated
                type_total[card_type] += 1
                type_allocated[card_type] += int(allocated)
                metrics = state.gpu_metrics.get((node.name, index)) if with_metrics else None
                if allocated:
                    if metrics is not None and metrics.utilisation is not None:
                        busy = metrics.utilisation >= IDLE_UTILISATION_THRESHOLD
                        card_state = "busy" if busy else "idle_allocated"
                        idle_allocated += int(not busy)
                    else:
                        card_state = "allocated"
                elif node.state in ("down", "drained"):
                    card_state = node.state
                else:
                    card_state = "free"
                cards.append(
                    GpuCard(
                        index=index,
                        state=card_state,  # type: ignore[arg-type]
                        utilisation=round(metrics.utilisation, 3)
                        if metrics and metrics.utilisation is not None
                        else None,
                        memory_used_mib=metrics.memory_used_mib if metrics else None,
                        memory_total_mib=metrics.memory_total_mib if metrics else None,
                        temperature_c=metrics.temperature_c if metrics else None,
                        power_w=metrics.power_w if metrics else None,
                        user=card_user.get((node.name, index)) if allocated else None,
                    )
                )
            node_type = Counter(node.gpu_types).most_common(1)[0][0]
            nodes.append(
                GpuNode(name=node.name, type=node_type, state=node.state, cards=cards)  # type: ignore[arg-type]
            )
        nodes.sort(key=lambda entry: (-type_total[entry.type], entry.type, entry.name))

        types = [
            GpuType(
                type=gpu_type,
                label=gpu_label(self._settings, gpu_type),
                total=total,
                allocated=type_allocated[gpu_type],
            )
            for gpu_type, total in type_total.items()
        ]
        types.sort(key=lambda entry: (-entry.total, entry.type))

        pending = [job for job in state.jobs if job.state == "PD" and job.gpu_count > 0]
        top_users = sorted(user_cards.items(), key=lambda item: (-item[1], item[0]))

        return Gpu(
            metrics_available=with_metrics,
            total=sum(type_total.values()),
            allocated=sum(type_allocated.values()),
            idle_allocated=idle_allocated if with_metrics else None,
            pending_jobs=len(pending),
            longest_wait_seconds=max((wait_seconds(job, now) for job in pending), default=0),
            types=types,
            nodes=nodes,
            top_users=[GpuUser(user=u, cards=c) for u, c in top_users[:TOP_USERS_LIMIT]],
            history=[
                GpuHistoryPoint(
                    t=iso_timestamp(point.t),
                    allocated_fraction=round(point.gpu_allocated / point.gpu_total, 3)
                    if point.gpu_total
                    else 0.0,
                    utilisation=round(point.gpu_utilisation, 3)
                    if with_metrics and point.gpu_utilisation is not None
                    else None,
                )
                for point in history
            ],
        )


class RunnersAggregator:
    def __init__(self, settings: RunnerSettings) -> None:
        self._extra = [(kind.key, kind.label) for kind in settings.extra]

    def build(self, state: ClusterState, user: str | None = None) -> Runners:
        now = state.polled_at
        ci = [job for job in state.jobs if job.runner_kind == "ci"]
        ci_waiting = [job for job in ci if job.state == "PD"]

        hub = [job for job in state.jobs if job.runner_kind == "jupyterhub" and job.state == "R"]
        near = 0
        for job in hub:
            left = remaining_seconds(job, now)
            near += int(left is not None and left < NEAR_WALLTIME_SECONDS)

        extra = []
        for key, label in self._extra:
            jobs = [job for job in state.jobs if job.runner_kind == f"extra:{key}"]
            running = sum(1 for job in jobs if job.state == "R")
            extra.append(
                ExtraRunners(key=key, label=label, running=running, pending=len(jobs) - running)
            )

        return Runners(
            ci=CiRunners(
                runners_alive=len(ci) - len(ci_waiting),
                jobs_waiting=len(ci_waiting),
                oldest_wait_seconds=max(wait_seconds(job, now) for job in ci_waiting)
                if ci_waiting
                else None,
            ),
            dask=DaskRunners(clusters=self._dask_clusters(state, user)),
            jupyterhub=JupyterHubRunners(
                sessions=len(hub),
                with_gpu=sum(1 for job in hub if job.gpu_count > 0),
                near_walltime=near,
            ),
            extra=extra,
        )

    @staticmethod
    def _dask_clusters(state: ClusterState, user: str | None) -> list[DaskCluster]:
        now = state.polled_at
        groups: dict[str, list[JobRecord]] = {}
        for job in state.jobs:
            if job.runner_kind == "dask":
                groups.setdefault(job.dask_cluster or job.user, []).append(job)

        clusters: list[DaskCluster] = []
        for cluster_id, jobs in groups.items():
            schedulers = [job for job in jobs if job.is_dask_scheduler]
            workers = [job for job in jobs if not job.is_dask_scheduler]
            owner = (schedulers or jobs)[0].user
            if user and owner != user:
                continue
            running = [job for job in workers if job.state == "R"]
            left = [
                seconds for job in running if (seconds := remaining_seconds(job, now)) is not None
            ]
            clusters.append(
                DaskCluster(
                    id=cluster_id,
                    owner=owner,
                    scheduler_alive=any(job.state == "R" for job in schedulers),
                    workers_running=len(running),
                    workers_requested=len(workers),
                    walltime_left_seconds=min(left) if left else None,
                )
            )
        clusters.sort(key=lambda cluster: (cluster.owner, cluster.id))
        return clusters[:DASK_CLUSTERS_LIMIT]
