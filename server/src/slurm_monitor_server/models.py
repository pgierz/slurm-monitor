"""Response models: the shapes of docs/contract.md, schema version 1."""

from __future__ import annotations

from typing import Generic, Literal, TypeVar

from pydantic import BaseModel, ConfigDict


class ContractModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


# --- not enveloped ---------------------------------------------------------


class Health(ContractModel):
    status: str
    version: str
    schema_version: int
    last_poll_at: str | None
    last_poll_ok: bool


class OidcClientConfig(ContractModel):
    issuer: str
    client_id: str
    scopes: list[str]


class AuthConfig(ContractModel):
    methods: list[Literal["token", "oidc"]]
    oidc: OidcClientConfig | None


class Me(ContractModel):
    method: Literal["token", "oidc"]
    subject: str
    username: str | None


# --- queue -----------------------------------------------------------------


class MineCounts(ContractModel):
    running: int
    pending: int


class ReasonCount(ContractModel):
    reason: str
    count: int


class MyJob(ContractModel):
    job_id: int
    name: str
    state: Literal["R", "PD"]
    partition: str
    resources: str
    elapsed_seconds: int
    time_limit_seconds: int | None
    estimated_start: str | None
    reason: str | None


class QueueHistoryPoint(ContractModel):
    t: str
    running: int
    pending: int


class Queue(ContractModel):
    partition: str | None
    qos: str | None
    user: str | None
    running: int
    pending: int
    mine: MineCounts | None
    pending_by_reason: list[ReasonCount]
    my_jobs_total: int
    my_jobs: list[MyJob]
    history: list[QueueHistoryPoint]


# --- nodes -----------------------------------------------------------------

NodeState = Literal["allocated", "idle", "drained", "down"]


class NodeEntry(ContractModel):
    name: str
    state: NodeState


class PartitionNodes(ContractModel):
    name: str
    total: int
    allocated: int
    idle: int
    drained: int
    down: int
    nodes: list[NodeEntry]


class Nodes(ContractModel):
    total: int
    allocated: int
    idle: int
    drained: int
    down: int
    partitions: list[PartitionNodes]


# --- qos -------------------------------------------------------------------


class QosEntry(ContractModel):
    name: str
    cpus_in_use: int
    cpu_limit: int | None
    running_jobs: int
    pending_jobs: int
    max_wall_seconds: int | None


class Qos(ContractModel):
    user: str | None
    account: str | None
    fairshare: float | None
    qos: list[QosEntry]


# --- gpu -------------------------------------------------------------------

CardState = Literal["busy", "idle_allocated", "allocated", "free", "drained", "down"]


class GpuCard(ContractModel):
    index: int
    state: CardState
    utilisation: float | None
    memory_used_mib: int | None
    memory_total_mib: int | None
    temperature_c: int | None
    power_w: int | None
    user: str | None


class GpuNode(ContractModel):
    name: str
    type: str
    state: NodeState
    cards: list[GpuCard]


class GpuType(ContractModel):
    type: str
    label: str
    total: int
    allocated: int


class GpuUser(ContractModel):
    user: str
    cards: int


class GpuHistoryPoint(ContractModel):
    t: str
    allocated_fraction: float
    utilisation: float | None


class Gpu(ContractModel):
    metrics_available: bool
    total: int
    allocated: int
    idle_allocated: int | None
    pending_jobs: int
    longest_wait_seconds: int
    types: list[GpuType]
    nodes: list[GpuNode]
    top_users: list[GpuUser]
    history: list[GpuHistoryPoint]


# --- runners ---------------------------------------------------------------


class CiRunners(ContractModel):
    runners_alive: int
    jobs_waiting: int
    oldest_wait_seconds: int | None


class DaskCluster(ContractModel):
    id: str
    owner: str
    scheduler_alive: bool
    workers_running: int
    workers_requested: int
    walltime_left_seconds: int | None


class DaskRunners(ContractModel):
    clusters: list[DaskCluster]


class JupyterHubRunners(ContractModel):
    sessions: int
    with_gpu: int
    near_walltime: int


class ExtraRunners(ContractModel):
    key: str
    label: str
    running: int
    pending: int


class Runners(ContractModel):
    ci: CiRunners
    dask: DaskRunners
    jupyterhub: JupyterHubRunners
    extra: list[ExtraRunners]


# --- envelope --------------------------------------------------------------

DataT = TypeVar("DataT", bound=BaseModel)


class Envelope(ContractModel, Generic[DataT]):
    schema_version: int
    cluster: str
    generated_at: str
    stale: bool
    data: DataT


class ErrorBody(ContractModel):
    error: str


FAMILY_MODELS: dict[str, type[BaseModel]] = {
    "queue": Queue,
    "nodes": Nodes,
    "qos": Qos,
    "gpu": Gpu,
    "runners": Runners,
}
