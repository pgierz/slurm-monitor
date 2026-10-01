"""A synthetic cluster in slurmrestd's JSON forms.

Used by the demo mode and by the tests. The cluster has 240 nodes in the
partitions mpp, smp, fat and gpu, GPU nodes with A40 and A100 cards, and
several hundred jobs including CI runners, Dask gateway clusters and
JupyterHub sessions. Everything is a deterministic function of the seed and
of the time asked for; as time advances, jobs age, finish and are replaced.

Two JSON forms are produced:

``wrapped``  mimics v0.0.40: numbers as ``{"set", "infinite", "number"}``
             objects, job and node states as lists of flags, the shares
             endpoint present.
``plain``    mimics v0.0.38: plain numbers, ``job_state`` a string, node
             ``state`` a string plus ``state_flags``, no shares endpoint.
"""

from __future__ import annotations

import hashlib
import math
import random
import re
import zlib
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from typing import Any, Literal

from .records import CardMetrics, GpuMetrics
from .slurmrestd import SlurmSourceError

Form = Literal["wrapped", "plain"]

USERS = (
    "alice", "bob", "carol", "dave", "erin", "frank", "grace",
    "heidi", "ivan", "judy", "mallory", "niaj", "olivia", "peggy",
)  # fmt: skip
# Some users submit much, one (grace) only little.
USER_WEIGHTS = (6, 6, 6, 5, 5, 5, 1, 4, 4, 4, 4, 4, 3, 3)
ACCOUNTS = ("hpc", "climate", "ocean", "bio")
CI_USER = "ci-service"
CORES_PER_NODE = 128
GPU_NODE_CORES = 64
GPU_MEMORY_MIB = {"a100": 40960, "a40": 46068}

# name → (max wall minutes, GrpTRES cpu)
QOS_TABLE: dict[str, tuple[int | None, int | None]] = {
    "30min": (30, None),
    "12h": (720, 18000),
    "48h": (2880, 8000),
    "1wk": (10080, 2000),
    "unused": (None, None),
}


@dataclass(slots=True)
class _Node:
    name: str
    partitions: list[str]
    cpus: int
    gpu_type: str = ""
    gpu_count: int = 0
    extra_flags: list[str] = field(default_factory=list)
    base_override: str | None = None  # e.g. "DOWN"
    usable: bool = True
    alloc_cpus: int = 0
    gpu_used: set[int] = field(default_factory=set)


@dataclass(slots=True)
class _Template:
    index: int
    name: str
    user: str
    partition: str
    qos: str
    limit_minutes: int | None
    nodes: int = 1
    cpus: int = 1  # total for shared jobs; whole nodes when exclusive
    exclusive: bool = False
    gpus: int = 0
    gpu_type: str = ""
    command: str = "/work/run.sh"
    comment: str = ""
    forced_reason: str | None = None
    run_seconds: int = 3600
    cycle_seconds: int = 3600
    offset: int = 0


@dataclass(slots=True)
class _Job:
    template: _Template
    job_id: int
    state: str
    reason: str
    submit_time: int
    start_time: int
    hosts: list[str]
    gpu_indices: list[int]


def _account(user: str) -> str:
    if user == CI_USER:
        return "hpc"
    return ACCOUNTS[USERS.index(user) % len(ACCOUNTS)]


def compress_hostlist(hosts: Sequence[str]) -> str:
    """``["prod-001", "prod-002", "prod-004"]`` → ``prod-[001-002,004]``."""
    groups: dict[tuple[str, int], list[int]] = {}
    for host in hosts:
        match = re.fullmatch(r"(.*?)(\d+)", host)
        if not match:
            groups.setdefault((host, 0), [])
            continue
        groups.setdefault((match.group(1), len(match.group(2))), []).append(int(match.group(2)))
    parts: list[str] = []
    for (prefix, width), numbers in groups.items():
        if not numbers:
            parts.append(prefix)
            continue
        numbers.sort()
        ranges: list[str] = []
        start = previous = numbers[0]
        for number in [*numbers[1:], None]:
            if number is not None and number == previous + 1:
                previous = number
                continue
            ranges.append(
                f"{start:0{width}d}" if start == previous
                else f"{start:0{width}d}-{previous:0{width}d}"
            )  # fmt: skip
            if number is not None:
                start = previous = number
        single = len(ranges) == 1 and "-" not in ranges[0]
        parts.append(f"{prefix}{ranges[0]}" if single else f"{prefix}[{','.join(ranges)}]")
    return ",".join(parts)


def _index_list(indices: Sequence[int]) -> str:
    text = compress_hostlist([f"x{index}" for index in indices])
    return text.replace("x", "").strip("[]")


class SyntheticCluster:
    def __init__(self, seed: int = 20261001) -> None:
        self.seed = seed
        self._templates = self._build_templates(random.Random(seed))
        self._cache: tuple[int, list[_Node], list[_Job]] | None = None

    # ----- static description ------------------------------------------------

    @staticmethod
    def _build_nodes() -> list[_Node]:
        nodes: list[_Node] = []
        nodes += [_Node(f"prod-{i:03d}", ["mpp"], CORES_PER_NODE) for i in range(1, 171)]
        nodes += [_Node(f"smp-{i:03d}", ["smp"], CORES_PER_NODE) for i in range(1, 53)]
        for i in range(1, 11):
            # The first two fat nodes also serve the smp partition.
            partitions = ["fat", "smp"] if i <= 2 else ["fat"]
            nodes.append(_Node(f"fat-{i:03d}", partitions, CORES_PER_NODE))
        nodes += [_Node(f"gpu-{i:03d}", ["gpu"], GPU_NODE_CORES, "a40", 2) for i in range(1, 5)]
        nodes += [_Node(f"gpu-{i:03d}", ["gpu"], GPU_NODE_CORES, "a100", 4) for i in range(5, 9)]

        by_name = {node.name: node for node in nodes}

        def mark(name: str, flags: list[str], base: str | None = None, usable: bool = False):
            node = by_name[name]
            node.extra_flags = flags
            node.base_override = base
            node.usable = usable

        mark("prod-017", [], base="DOWN")
        mark("prod-088", ["DRAIN"], base="DOWN")
        mark("prod-101", ["NOT_RESPONDING"])
        mark("fat-010", ["POWERED_DOWN"])
        for number in range(40, 45):
            mark(f"prod-{number:03d}", ["DRAIN"])
        mark("prod-045", ["DRAIN"], usable=True)  # draining while still allocated
        mark("prod-150", ["RESERVED"])
        mark("smp-050", ["MAINT"])
        mark("smp-051", ["DRAIN"])
        mark("gpu-004", ["DRAIN"])
        return nodes

    @staticmethod
    def _build_templates(rng: random.Random) -> list[_Template]:
        templates: list[_Template] = []

        def add(**values: Any) -> _Template:
            limit = values.get("limit_minutes")
            limit_seconds = limit * 60 if limit else 5 * 86400
            fixed = values.pop("always_active", False)
            run = limit_seconds if fixed else int(limit_seconds * rng.uniform(0.5, 1.0))
            cycle = run if fixed else run + int(limit_seconds * rng.uniform(0.0, 0.08))
            template = _Template(
                index=len(templates),
                run_seconds=run,
                cycle_seconds=cycle,
                offset=rng.randrange(cycle),
                **values,
            )
            templates.append(template)
            return template

        def pick_user() -> str:
            return rng.choices(USERS, weights=USER_WEIGHTS)[0]

        def limit_for(qos: str) -> int:
            maximum = QOS_TABLE[qos][0] or 720
            return rng.choice([maximum, maximum, maximum // 2, max(10, maximum // 4)])

        # CI runners: four alive, seven waiting.
        for number in range(11):
            add(name=f"ci-{88120 + number}", user=CI_USER, partition="smp", qos="30min",
                limit_minutes=30, cpus=4, command="/opt/ci/run-job.sh",
                forced_reason="Priority" if number >= 4 else None, always_active=True)  # fmt: skip

        # Dask gateway clusters. The first two are told apart by the job
        # comment; the third has no comment and falls back to its owner.
        dask = [("a3f1", "alice", 16, 2, False), ("b7c2", "bob", 8, 0, False),
                ("", "carol", 4, 4, True)]  # fmt: skip
        for comment, owner, workers, waiting, scheduler_waits in dask:
            add(name="dask-gateway", user=owner, partition="smp", qos="12h", limit_minutes=240,
                cpus=2, command="/opt/dask/bin/dask-scheduler --protocol tls", comment=comment,
                forced_reason="Priority" if scheduler_waits else None,
                always_active=True)  # fmt: skip
            for number in range(workers):
                add(name="dask-gateway", user=owner, partition="smp", qos="12h",
                    limit_minutes=rng.choice([90, 120, 180]), cpus=16,
                    command="/opt/dask/bin/dask-worker --nthreads 16", comment=comment,
                    forced_reason="Resources" if number >= workers - waiting else None,
                    always_active=True)  # fmt: skip

        # JupyterHub sessions, four of them with a GPU.
        for number in range(23):
            with_gpu = number < 4
            add(name="spawner-jupyterhub", user=USERS[(number * 5) % len(USERS)],
                partition="gpu" if with_gpu else "smp", qos="12h", limit_minutes=480,
                cpus=8 if with_gpu else 4, gpus=1 if with_gpu else 0,
                gpu_type="a40" if with_gpu else "",
                command="/opt/jupyterhub/bin/batchspawner-singleuser",
                always_active=True)  # fmt: skip

        for number in range(3):
            add(name=f"matlab-batch-{number}", user=USERS[number + 3], partition="smp",
                qos="12h", limit_minutes=360, cpus=8, command="/work/matlab.sh",
                always_active=True)  # fmt: skip

        models = ("awiesm", "fesom", "icon", "echam", "oifs", "recom")
        for number in range(70):
            qos = rng.choice(["12h", "12h", "12h", "48h", "30min"])
            nodes = rng.choices([1, 2, 4, 8, 16, 32], weights=[40, 20, 15, 12, 9, 4])[0]
            add(name=f"{rng.choice(models)}_run{number:03d}", user=pick_user(),
                partition="mpp", qos=qos, limit_minutes=limit_for(qos), nodes=nodes,
                cpus=nodes * CORES_PER_NODE, exclusive=True)  # fmt: skip

        forced = (["QOSGrpCpuLimit"] * 6 + ["QOSMaxJobsPerUserLimit"] * 2 + ["AssocGrpCpuLimit"] * 2
                  + ["Dependency"] * 3 + ["JobHeldUser"] * 3 + ["JobHeldAdmin"]
                  + ["BeginTime"] * 2 + ["ReqNodeNotAvail"])  # fmt: skip
        tools = ("postproc", "cdo_remap", "pycmor", "regrid", "analysis", "plot", "tar_archive")
        for number in range(380):
            qos = rng.choice(["12h", "12h", "48h", "30min", "30min"])
            cores = rng.choices([1, 4, 8, 16, 32, 64], weights=[30, 25, 20, 15, 7, 3])[0]
            reason = forced[number] if number < len(forced) else None
            add(name=f"{rng.choice(tools)}_{number:03d}", user=pick_user(),
                # Some waiting jobs ask for either of two partitions.
                partition="smp,fat" if reason == "Dependency" else "smp",
                qos=qos, limit_minutes=limit_for(qos), cpus=cores,
                forced_reason=reason)  # fmt: skip

        for number in range(14):
            add(name=f"highmem_{number:02d}", user=pick_user(), partition="fat",
                qos="48h", limit_minutes=limit_for("48h"), cpus=CORES_PER_NODE,
                exclusive=True)  # fmt: skip

        # One job without a time limit.
        add(name="longrunner", user="alice", partition="smp", qos="1wk", limit_minutes=None,
            cpus=2)  # fmt: skip

        for number in range(22):
            gpu_type = rng.choice(["a100", "a100", "a40"])
            gpus = rng.choice([1, 1, 2, 4]) if gpu_type == "a100" else rng.choice([1, 1, 2])
            add(name=f"train_{number:02d}", user=pick_user(), partition="gpu",
                qos="12h", limit_minutes=limit_for("12h"), cpus=8 * gpus, gpus=gpus,
                gpu_type=gpu_type, command="/work/train.py")  # fmt: skip
        return templates

    # ----- simulation at one moment ------------------------------------------

    def _stable(self, *parts: object) -> float:
        """A reproducible pseudo-random number in [0, 1) from the given parts."""
        text = ":".join(str(part) for part in (self.seed, *parts))
        digest = hashlib.blake2b(text.encode(), digest_size=8).digest()
        return int.from_bytes(digest, "big") / 2**64

    def simulate(self, now: int) -> tuple[list[_Node], list[_Job]]:
        if self._cache is not None and self._cache[0] == now:
            return self._cache[1], self._cache[2]
        nodes = self._build_nodes()
        jobs: list[_Job] = []
        waiting_in_partition: dict[str, int] = {}

        for template in self._templates:
            position = (now + template.offset) % template.cycle_seconds
            if position >= template.run_seconds:
                continue  # between two runs of this template
            cycle = (now + template.offset) // template.cycle_seconds
            job_id = 4_000_000 + (cycle % 900) * 1000 + template.index

            hosts: list[str] = []
            gpu_indices: list[int] = []
            if template.forced_reason is None:
                hosts, gpu_indices = self._allocate(template, nodes)
            if hosts:
                jobs.append(_Job(template, job_id, "RUNNING", "None", now - position - 120,
                                 now - position, hosts, gpu_indices))  # fmt: skip
                continue

            reason = template.forced_reason
            if reason is None:
                order = waiting_in_partition.get(template.partition, 0)
                waiting_in_partition[template.partition] = order + 1
                reason = "Resources" if order < 3 or order % 3 == 0 else "Priority"
            expected = 0
            if reason in ("Resources", "Priority") and self._stable("eta", job_id) < 0.6:
                expected = now + 600 + int(self._stable("eta2", job_id) * 7200)
                expected -= expected % 60
            jobs.append(_Job(template, job_id, "PENDING", reason, now - position, expected, [], []))

        self._cache = (now, nodes, jobs)
        return nodes, jobs

    @staticmethod
    def _allocate(template: _Template, nodes: list[_Node]) -> tuple[list[str], list[int]]:
        partitions = template.partition.split(",")
        candidates = [
            node for node in nodes
            if node.usable and any(name in node.partitions for name in partitions)
        ]  # fmt: skip
        if template.exclusive:
            free = [node for node in candidates if node.alloc_cpus == 0][: template.nodes]
            if len(free) < template.nodes:
                return [], []
            for node in free:
                node.alloc_cpus = node.cpus
            return [node.name for node in free], []
        for node in candidates:
            if node.cpus - node.alloc_cpus < template.cpus:
                continue
            if template.gpus:
                if node.gpu_type != template.gpu_type:
                    continue
                free_cards = [i for i in range(node.gpu_count) if i not in node.gpu_used]
                if len(free_cards) < template.gpus:
                    continue
                chosen = free_cards[: template.gpus]
                node.gpu_used.update(chosen)
                node.alloc_cpus += template.cpus
                return [node.name], chosen
            node.alloc_cpus += template.cpus
            return [node.name], []
        return [], []

    # ----- payloads ----------------------------------------------------------

    @staticmethod
    def _number(value: int | None, form: Form, infinite: bool = False) -> Any:
        if form == "plain":
            if infinite:
                return 0xFFFFFFFF  # INFINITE, as an untranslated 32-bit value
            return value if value is not None else 0
        return {
            "set": value is not None and not infinite,
            "infinite": infinite,
            "number": value if value is not None and not infinite else 0,
        }

    @staticmethod
    def _envelope(form: Form, key: str, value: Any) -> dict[str, Any]:
        version = "v0.0.40" if form == "wrapped" else "v0.0.38"
        return {
            "meta": {"plugin": {"type": f"openapi/{version}", "name": "Slurm OpenAPI"}},
            "errors": [],
            "warnings": [],
            key: value,
        }

    def jobs_payload(self, now: int, form: Form = "wrapped") -> dict[str, Any]:
        _, jobs = self.simulate(now)
        number = self._number
        entries: list[dict[str, Any]] = []
        for job in jobs:
            template = job.template
            running = job.state == "RUNNING"
            tres = f"cpu={template.cpus},mem={template.cpus * 2}G,node={template.nodes}"
            tres += f",billing={template.cpus}"
            per_node = ""
            gres_detail: list[str] = []
            if template.gpus:
                tres += f",gres/gpu={template.gpus},gres/gpu:{template.gpu_type}={template.gpus}"
                prefix = "gres/" if form == "wrapped" else ""
                per_node = f"{prefix}gpu:{template.gpu_type}:{template.gpus}"
                if running:
                    gres_detail = [
                        f"gpu:{template.gpu_type}:{template.gpus}"
                        f"(IDX:{_index_list(job.gpu_indices)})"
                    ]
            entries.append(
                {
                    "job_id": job.job_id,
                    "name": template.name,
                    "user_name": template.user,
                    "user_id": 20000 + zlib.crc32(template.user.encode()) % 1000,
                    "account": _account(template.user),
                    "partition": template.partition if not running else job_partition(job),
                    "qos": template.qos,
                    "job_state": [job.state] if form == "wrapped" else job.state,
                    "state_reason": job.reason,
                    "state_description": "",
                    "submit_time": number(job.submit_time, form),
                    "start_time": number(job.start_time, form),
                    "end_time": number(
                        job.start_time + template.limit_minutes * 60
                        if running and template.limit_minutes
                        else 0,
                        form,
                    ),
                    "time_limit": number(
                        template.limit_minutes, form, infinite=template.limit_minutes is None
                    ),
                    "node_count": number(template.nodes, form),
                    "cpus": number(template.cpus, form),
                    "tasks": number(template.cpus, form),
                    "priority": number(1000 + template.index, form),
                    "nodes": compress_hostlist(job.hosts),
                    "batch_host": job.hosts[0] if job.hosts else "",
                    "command": template.command,
                    "comment": template.comment,
                    "tres_req_str": tres,
                    "tres_alloc_str": tres if running else "",
                    "tres_per_node": per_node,
                    "gres_detail": gres_detail,
                }
            )
        # Jobs in other states, which the server must leave out.
        for index, state in enumerate(["COMPLETED", "CANCELLED", "FAILED", "TIMEOUT"]):
            entries.append(
                {
                    "job_id": 3_990_000 + index,
                    "name": f"finished_{index}",
                    "user_name": "alice",
                    "account": "hpc",
                    "partition": "smp",
                    "qos": "12h",
                    "job_state": [state] if form == "wrapped" else state,
                    "state_reason": "None",
                    "submit_time": number(now - 9000, form),
                    "start_time": number(now - 8000, form),
                    "time_limit": number(60, form),
                    "node_count": number(1, form),
                    "cpus": number(4, form),
                    "nodes": "smp-001",
                    "tres_per_node": "",
                    "gres_detail": [],
                }
            )
        return self._envelope(form, "jobs", entries)

    def nodes_payload(self, now: int, form: Form = "wrapped") -> dict[str, Any]:
        nodes, _ = self.simulate(now)
        entries: list[dict[str, Any]] = []
        for node in nodes:
            if node.base_override:
                base = node.base_override
            elif node.alloc_cpus == 0:
                base = "IDLE"
            elif node.alloc_cpus >= node.cpus:
                base = "ALLOCATED"
            else:
                base = "MIXED"
            entry: dict[str, Any] = {
                "name": node.name,
                "hostname": node.name,
                "partitions": list(node.partitions),
                "cpus": node.cpus,
                "alloc_cpus": node.alloc_cpus,
                "real_memory": 256000,
                "reason": "maintenance" if node.extra_flags or node.base_override else "",
                "gres": "",
                "gres_used": "",
            }
            if form == "wrapped":
                entry["state"] = [base, *node.extra_flags]
            else:
                entry["state"] = base.lower()
                entry["state_flags"] = list(node.extra_flags)
            if node.gpu_count:
                used = sorted(node.gpu_used)
                index_text = _index_list(used) if used else "N/A"
                entry["gres"] = f"gpu:{node.gpu_type}:{node.gpu_count}(S:0-1)"
                entry["gres_used"] = f"gpu:{node.gpu_type}:{len(used)}(IDX:{index_text})"
            entries.append(entry)
        return self._envelope(form, "nodes", entries)

    def partitions_payload(self, now: int, form: Form = "wrapped") -> dict[str, Any]:
        nodes, _ = self.simulate(now)
        members: dict[str, list[str]] = {}
        for node in nodes:
            for name in node.partitions:
                members.setdefault(name, []).append(node.name)
        entries: list[dict[str, Any]] = []
        for name, hosts in members.items():
            if form == "wrapped":
                entries.append(
                    {
                        "name": name,
                        "nodes": {"configured": compress_hostlist(hosts), "total": len(hosts)},
                        "partition": {"state": ["UP"]},
                    }
                )
            else:
                entries.append(
                    {
                        "name": name,
                        "nodes": compress_hostlist(hosts),
                        "total_nodes": len(hosts),
                        "state": "UP",
                    }
                )
        return self._envelope(form, "partitions", entries)

    def qos_payload(self, now: int, form: Form = "wrapped") -> dict[str, Any]:
        entries: list[dict[str, Any]] = []
        for identifier, (name, (wall, cpu_limit)) in enumerate(QOS_TABLE.items(), start=1):
            total = [{"type": "cpu", "name": "", "id": 1, "count": cpu_limit}] if cpu_limit else []
            entries.append(
                {
                    "id": identifier,
                    "name": name,
                    "description": name,
                    "limits": {
                        "max": {
                            "tres": {"total": total, "per": {"job": [], "user": []}},
                            "wall_clock": {
                                "per": {
                                    "job": self._number(wall, form)
                                    if form == "wrapped" or wall is not None
                                    else None,
                                    "qos": self._number(None, form) if form == "wrapped" else None,
                                }
                            },
                        }
                    },
                }
            )
        return self._envelope(form, "qos", entries)

    def shares_payload(self, now: int, form: Form = "wrapped") -> dict[str, Any]:
        if form == "plain":
            # v0.0.38 has no shares endpoint.
            raise SlurmSourceError("/slurm/v0.0.38/shares: HTTP 404")
        rows: list[dict[str, Any]] = [
            {
                "id": 1,
                "cluster": "synthetic",
                "name": "root",
                "parent": "",
                "type": ["ASSOCIATION"],
                "fairshare": {"factor": 1.0, "level": 1.0},
            }  # fmt: skip
        ]
        for account in ACCOUNTS:
            rows.append(
                {
                    "id": len(rows) + 1,
                    "cluster": "synthetic",
                    "name": account,
                    "parent": "root",
                    "type": ["ASSOCIATION"],
                    "fairshare": {"factor": 0.0, "level": 0.25},
                }  # fmt: skip
            )
        for user in USERS:
            factor = 0.42 if user == "alice" else round(0.05 + 0.9 * self._stable("fs", user), 4)
            rows.append(
                {
                    "id": len(rows) + 1,
                    "cluster": "synthetic",
                    "name": user,
                    "parent": _account(user),
                    "partition": "",
                    "shares": self._number(1, "wrapped"),
                    "shares_normalized": self._number(0, "wrapped"),
                    "effective_usage": 0.01,
                    "fairshare": {"factor": factor, "level": round(factor * 2, 4)},
                    "type": ["USER"],
                }
            )
        return self._envelope(form, "shares", {"shares": rows, "total_shares": len(rows)})

    # ----- GPU metrics of the demo mode --------------------------------------

    def gpu_metrics(self, now: int) -> GpuMetrics:
        nodes, _ = self.simulate(now)
        metrics: GpuMetrics = {}
        for node in nodes:
            if not node.usable and not node.gpu_used and node.base_override:
                continue  # a node that is down reports nothing
            for index in range(node.gpu_count):
                total = GPU_MEMORY_MIB[node.gpu_type]
                utilisation = 0.0
                if index in node.gpu_used:
                    chance = self._stable("card", node.name, index)
                    if chance < 0.2:
                        utilisation = 0.03 * self._stable("idle", node.name, index)
                    else:
                        wobble = 0.04 * math.sin(now / 600 + chance * 6.28)
                        utilisation = min(1.0, 0.5 + 0.48 * chance + wobble)
                metrics[(node.name, index)] = CardMetrics(
                    utilisation=round(utilisation, 3),
                    memory_used_mib=round(3 + utilisation * 0.9 * total),
                    memory_total_mib=total,
                    temperature_c=round(34 + utilisation * 41),
                    power_w=round(55 + utilisation * 235),
                )
        return metrics


def job_partition(job: _Job) -> str:
    """A running job reports the one partition it runs in."""
    return job.template.partition.split(",")[0]


class SyntheticSlurmSource:
    """Serves the synthetic cluster through the same interface as slurmrestd."""

    def __init__(
        self, cluster: SyntheticCluster, clock: Callable[[], float], form: Form = "wrapped"
    ) -> None:
        self._cluster = cluster
        self._clock = clock
        self._form: Form = form

    async def fetch_jobs(self) -> dict[str, Any]:
        return self._cluster.jobs_payload(int(self._clock()), self._form)

    async def fetch_nodes(self) -> dict[str, Any]:
        return self._cluster.nodes_payload(int(self._clock()), self._form)

    async def fetch_partitions(self) -> dict[str, Any]:
        return self._cluster.partitions_payload(int(self._clock()), self._form)

    async def fetch_qos(self) -> dict[str, Any]:
        return self._cluster.qos_payload(int(self._clock()), self._form)

    async def fetch_shares(self) -> dict[str, Any]:
        return self._cluster.shares_payload(int(self._clock()), self._form)


class SyntheticGpuMetrics:
    """GPU metrics of the synthetic cluster, for the demo mode and the tests."""

    provides_metrics = True

    def __init__(self, cluster: SyntheticCluster, clock: Callable[[], float]) -> None:
        self._cluster = cluster
        self._clock = clock

    async def read(self, nodes: Sequence[str]) -> GpuMetrics:
        wanted = set(nodes)
        metrics = self._cluster.gpu_metrics(int(self._clock()))
        return {key: value for key, value in metrics.items() if key[0] in wanted}

    async def close(self) -> None:
        return None
