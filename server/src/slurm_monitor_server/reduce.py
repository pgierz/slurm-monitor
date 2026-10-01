"""Reduction of raw slurmrestd payloads to compact records."""

from __future__ import annotations

import logging
import re
from typing import Any

from .config import RunnerSettings
from .records import JobRecord, NodeRecord, QosRecord, ShareRecord
from .slurm_parsing import (
    GresEntry,
    expand_hostlist,
    parse_float,
    parse_gres,
    parse_int,
    parse_number,
    parse_state_flags,
    parse_text,
    parse_timestamp,
    parse_tres_count,
)

logger = logging.getLogger(__name__)

# slurmrestd gives a base state plus flags. It spells the maintenance flag
# MAINTENANCE and never emits DRAINING or DRAINED (those are sinfo's words for
# base state plus DRAIN); the sinfo spellings are accepted all the same.
DOWN_FLAGS = {"DOWN", "FAIL", "NOT_RESPONDING", "ERROR", "INVALID_REG", "UNKNOWN"}
DRAINED_FLAGS = {"DRAIN", "MAINTENANCE", "MAINT", "DRAINING", "DRAINED"}
ALLOCATED_FLAGS = {"ALLOCATED", "MIXED", "COMPLETING"}
# A node that only exists as a FUTURE definition is not part of the cluster.
OMITTED_FLAG = "FUTURE"
# More cards than this on one node is a misread GRES string, not hardware.
MAX_CARDS_PER_NODE = 64
# A time limit beyond ten years is a sentinel or garbage: reported as unknown.
MAX_TIME_LIMIT_MINUTES = 10 * 366 * 24 * 60


def map_node_state(flags: list[str]) -> str:
    """Contract node state from Slurm state flags, in the contract's order.

    Everything not named counts as idle; that includes POWERED_DOWN,
    POWERING_UP, POWERING_DOWN, REBOOT_ISSUED, CLOUD and PLANNED, because
    with power saving such nodes are available to the scheduler.
    """
    present = set(flags)
    if present & DOWN_FLAGS:
        return "down"
    if present & DRAINED_FLAGS:
        return "drained"
    if present & ALLOCATED_FLAGS:
        return "allocated"
    if "RESERVED" in present:
        # An idle node held by a reservation is not available.
        return "drained"
    return "idle"


class RunnerClassifier:
    """Assigns jobs to runner kinds by regular expressions on the job name."""

    def __init__(self, settings: RunnerSettings) -> None:
        self._ci = re.compile(settings.ci_pattern)
        self._dask = re.compile(settings.dask_pattern)
        self._dask_scheduler = re.compile(settings.dask_scheduler_pattern)
        self._jupyterhub = re.compile(settings.jupyterhub_pattern)
        self._extra = [(kind.key, re.compile(kind.pattern)) for kind in settings.extra]
        self.dask_cluster_field = settings.dask_cluster_field

    def kind(self, name: str) -> str | None:
        if self._ci.search(name):
            return "ci"
        if self._dask.search(name):
            return "dask"
        if self._jupyterhub.search(name):
            return "jupyterhub"
        for key, pattern in self._extra:
            if pattern.search(name):
                return f"extra:{key}"
        return None

    def is_dask_scheduler(self, name: str, command: str) -> bool:
        return bool(self._dask_scheduler.search(name) or self._dask_scheduler.search(command))


def _gpu_entries(text: Any, gres_name: str) -> list[GresEntry]:
    return [entry for entry in parse_gres(text) if entry.name == gres_name]


def _gpu_type_from_tres(text: Any, gres_name: str) -> str:
    if not isinstance(text, str):
        return ""
    match = re.search(rf"gres/{re.escape(gres_name)}:([^=,]+)=", text)
    return match.group(1).lower() if match else ""


def _job_gpus(
    job: dict[str, Any], state: str, node_count: int, gres_name: str
) -> tuple[int, str, tuple[tuple[str, int], ...]]:
    """GPU count, GPU type and (node, card index) pairs of one job."""
    count = 0
    gpu_type = ""
    cards: list[tuple[str, int]] = []

    if state == "R":
        detail = job.get("gres_detail")
        if isinstance(detail, list) and detail:
            hosts = expand_hostlist(job.get("nodes"))
            per_node = [_gpu_entries(item, gres_name) for item in detail]
            for position, entries in enumerate(per_node):
                for entry in entries:
                    count += entry.count
                    gpu_type = gpu_type or entry.type
                    if entry.indices and len(hosts) == len(per_node):
                        cards.extend(
                            (hosts[position], index)
                            for index in entry.indices
                            if index < MAX_CARDS_PER_NODE
                        )
        if count == 0:
            count = parse_tres_count(job.get("tres_alloc_str"), f"gres/{gres_name}") or 0
            gpu_type = gpu_type or _gpu_type_from_tres(job.get("tres_alloc_str"), gres_name)

    if count == 0:
        count = parse_tres_count(job.get("tres_req_str"), f"gres/{gres_name}") or 0
    for field_name, factor in (("tres_per_node", max(node_count, 1)), ("tres_per_job", 1)):
        entries = _gpu_entries(job.get(field_name), gres_name)
        if entries:
            if count == 0:
                count = sum(entry.count for entry in entries) * factor
            gpu_type = gpu_type or next((e.type for e in entries if e.type), "")
    if count == 0:
        # Oldest form: a plain "gres" request string on the job.
        entries = _gpu_entries(job.get("gres"), gres_name)
        count = sum(entry.count for entry in entries) * max(node_count, 1)
        gpu_type = gpu_type or next((e.type for e in entries if e.type), "")
    if count and not gpu_type:
        gpu_type = _gpu_type_from_tres(job.get("tres_req_str"), gres_name)
    if count == 0:
        gpu_type = ""
    return count, gpu_type, tuple(cards)


def reduce_job(
    job: dict[str, Any], classifier: RunnerClassifier, gres_name: str
) -> JobRecord | None:
    """One compact record, or None for jobs that are neither running nor pending."""
    flags = parse_state_flags(job.get("job_state"))
    if "RUNNING" in flags:
        state = "R"
    elif "PENDING" in flags:
        state = "PD"
    else:
        return None
    job_id = parse_int(job.get("job_id"))
    if job_id is None:
        return None

    name = parse_text(job.get("name"))
    user = parse_text(job.get("user_name")) or parse_text(job.get("user_id"))
    limit = parse_number(job.get("time_limit"))  # minutes
    time_limit = (
        int(limit.value * 60)
        if limit.is_set and limit.value is not None and 0 <= limit.value <= MAX_TIME_LIMIT_MINUTES
        else None
    )
    node_count = parse_int(job.get("node_count")) or 0
    cpus = parse_int(job.get("cpus")) or 0
    gpu_count, gpu_type, gpu_cards = _job_gpus(job, state, node_count, gres_name)

    kind = classifier.kind(name)
    is_scheduler = kind == "dask" and classifier.is_dask_scheduler(
        name, parse_text(job.get("command"))
    )
    cluster = parse_text(job.get(classifier.dask_cluster_field)) if kind == "dask" else ""

    return JobRecord(
        job_id=job_id,
        name=name,
        user=user,
        account=parse_text(job.get("account")),
        partition=parse_text(job.get("partition")),
        qos=parse_text(job.get("qos")),
        state=state,
        reason=parse_text(job.get("state_reason")),
        submit_time=parse_timestamp(job.get("submit_time")),
        start_time=parse_timestamp(job.get("start_time")),
        time_limit_seconds=time_limit,
        node_count=node_count,
        cpus=cpus,
        gpu_count=gpu_count,
        gpu_type=gpu_type,
        gpu_cards=gpu_cards,
        runner_kind=kind,
        is_dask_scheduler=is_scheduler,
        dask_cluster=cluster.strip(),
    )


def reduce_jobs(
    payload: dict[str, Any], classifier: RunnerClassifier, gres_name: str = "gpu"
) -> tuple[JobRecord, ...]:
    jobs = payload.get("jobs")
    if not isinstance(jobs, list):
        raise ValueError("jobs payload has no 'jobs' list")
    records = (reduce_job(job, classifier, gres_name) for job in jobs if isinstance(job, dict))
    return tuple(record for record in records if record is not None)


def jobs_without_user_name(payload: dict[str, Any]) -> int:
    """How many running or pending jobs carry an empty ``user_name``.

    slurmrestd leaves the name empty when it cannot resolve a uid; such jobs
    are then never counted as anybody's own.
    """
    jobs = payload.get("jobs")
    if not isinstance(jobs, list):
        return 0
    count = 0
    for job in jobs:
        if not isinstance(job, dict) or parse_text(job.get("user_name")):
            continue
        flags = parse_state_flags(job.get("job_state"))
        count += int("RUNNING" in flags or "PENDING" in flags)
    return count


def partition_membership(payload: dict[str, Any] | None) -> dict[str, list[str]]:
    """Node name → partition names, from the partitions endpoint.

    Used only for nodes whose own record names no partitions.
    """
    membership: dict[str, list[str]] = {}
    if not payload or not isinstance(payload.get("partitions"), list):
        return membership
    for partition in payload["partitions"]:
        if not isinstance(partition, dict):
            continue
        name = parse_text(partition.get("name"))
        nodes = partition.get("nodes")
        # v0.0.40+: {"nodes": {"configured": "prod-[001-170]", "total": 170}};
        # older: {"nodes": "prod-[001-170]"}.
        hostlist = nodes.get("configured") if isinstance(nodes, dict) else nodes
        for host in expand_hostlist(hostlist):
            membership.setdefault(host, []).append(name)
    return membership


def reduce_node(
    node: dict[str, Any], membership: dict[str, list[str]], gres_name: str
) -> NodeRecord | None:
    name = parse_text(node.get("name")) or parse_text(node.get("hostname"))
    if not name:
        return None
    # Older payloads: "state": "idle", "state_flags": ["DRAIN"]. Newer: a list.
    flags = parse_state_flags(node.get("state"), node.get("state_flags"))
    if OMITTED_FLAG in flags:
        return None
    state = map_node_state(flags)

    raw_partitions = node.get("partitions")
    if isinstance(raw_partitions, str):
        partitions = [part.strip() for part in raw_partitions.split(",") if part.strip()]
    elif isinstance(raw_partitions, list):
        partitions = [part for part in raw_partitions if isinstance(part, str) and part]
    else:
        partitions = []
    if not partitions:
        partitions = membership.get(name, [])

    gpu_types: list[str] = []
    for entry in _gpu_entries(node.get("gres"), gres_name):
        room = MAX_CARDS_PER_NODE - len(gpu_types)
        if entry.count > room:
            logger.debug("node %s: GRES card count capped at %d", name, MAX_CARDS_PER_NODE)
        gpu_types.extend([entry.type or gres_name] * max(0, min(entry.count, room)))

    allocated: set[int] = set()
    for entry in _gpu_entries(node.get("gres_used"), gres_name):
        if entry.indices is not None and (entry.indices or entry.count == 0):
            allocated.update(index for index in entry.indices if index < len(gpu_types))
            continue
        # No usable IDX list: mark the first free cards of that type.
        wanted = entry.type or None
        remaining = entry.count
        for index, card_type in enumerate(gpu_types):
            if remaining == 0:
                break
            if index in allocated or (wanted and card_type != wanted):
                continue
            allocated.add(index)
            remaining -= 1

    return NodeRecord(
        name=name,
        state=state,
        partitions=tuple(partitions),
        gpu_types=tuple(gpu_types),
        gpu_allocated=frozenset(allocated),
    )


def reduce_nodes(
    payload: dict[str, Any], partitions_payload: dict[str, Any] | None, gres_name: str = "gpu"
) -> tuple[NodeRecord, ...]:
    nodes = payload.get("nodes")
    if not isinstance(nodes, list):
        raise ValueError("nodes payload has no 'nodes' list")
    membership = partition_membership(partitions_payload)
    records = (reduce_node(node, membership, gres_name) for node in nodes if isinstance(node, dict))
    return tuple(sorted((r for r in records if r is not None), key=lambda r: r.name))


def _dig(value: Any, *keys: str) -> Any:
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def reduce_qos(payload: dict[str, Any] | None) -> tuple[QosRecord, ...]:
    if not payload or not isinstance(payload.get("qos"), list):
        return ()
    records: list[QosRecord] = []
    for qos in payload["qos"]:
        if not isinstance(qos, dict) or not parse_text(qos.get("name")):
            continue
        cpu_limit: int | None = None
        # GrpTRES: limits.max.tres.total, a list of {type, name, id, count}.
        total = _dig(qos, "limits", "max", "tres", "total")
        if isinstance(total, list):
            for tres in total:
                if isinstance(tres, dict) and parse_text(tres.get("type")).lower() == "cpu":
                    count = parse_int(tres.get("count"))
                    cpu_limit = count if count is not None and count >= 0 else None
        # MaxWall: limits.max.wall_clock.per.job, in minutes.
        wall = parse_number(_dig(qos, "limits", "max", "wall_clock", "per", "job"))
        max_wall = int(wall.value * 60) if wall.is_set and wall.value is not None else None
        records.append(QosRecord(parse_text(qos["name"]), cpu_limit, max_wall))
    return tuple(records)


def reduce_shares(payload: dict[str, Any] | None) -> tuple[ShareRecord, ...]:
    """User rows of the shares endpoint (sshare's view of the associations)."""
    if not payload:
        return ()
    rows = payload.get("shares")
    if isinstance(rows, dict):
        rows = rows.get("shares")
    if not isinstance(rows, list):
        return ()
    records: list[ShareRecord] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        if "USER" not in parse_state_flags(row.get("type")):
            continue
        user = parse_text(row.get("name"))
        if not user:
            continue
        raw = row.get("fairshare")
        # v0.0.40: fairshare.factor is a plain number; v0.0.41+: a number object.
        factor = parse_float(raw.get("factor") if isinstance(raw, dict) else raw)
        if factor is not None:
            factor = min(1.0, max(0.0, factor))
        records.append(
            ShareRecord(user=user, account=parse_text(row.get("parent")), fairshare=factor)
        )
    return tuple(records)
