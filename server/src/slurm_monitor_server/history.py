"""Short in-memory history: one point per five minutes, at most 72 points."""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass

from .records import ClusterState

BUCKET_SECONDS = 300
MAX_POINTS = 72


@dataclass(frozen=True, slots=True)
class HistoryPoint:
    t: int  # start of the five-minute bucket, Unix seconds
    # (partition string, qos) → (running, pending); lets the queue history
    # follow the partition and qos filters without storing jobs.
    queue_counts: dict[tuple[str, str], tuple[int, int]]
    gpu_total: int
    gpu_allocated: int
    gpu_utilisation: float | None  # mean over allocated cards, None without metrics


def mean_allocated_utilisation(state: ClusterState) -> float | None:
    if not state.metrics_available:
        return None
    values = [
        metrics.utilisation
        for node in state.nodes
        for index in node.gpu_allocated
        if (metrics := state.gpu_metrics.get((node.name, index))) is not None
        and metrics.utilisation is not None
    ]
    return sum(values) / len(values) if values else None


def make_point(state: ClusterState) -> HistoryPoint:
    counts: dict[tuple[str, str], list[int]] = {}
    for job in state.jobs:
        entry = counts.setdefault((job.partition, job.qos), [0, 0])
        entry[0 if job.state == "R" else 1] += 1
    return HistoryPoint(
        t=state.polled_at // BUCKET_SECONDS * BUCKET_SECONDS,
        queue_counts={key: (value[0], value[1]) for key, value in counts.items()},
        gpu_total=sum(len(node.gpu_types) for node in state.nodes),
        gpu_allocated=sum(len(node.gpu_allocated) for node in state.nodes),
        gpu_utilisation=mean_allocated_utilisation(state),
    )


class HistoryStore:
    """Keeps the latest sample of each five-minute bucket."""

    def __init__(self, window_seconds: int = MAX_POINTS * BUCKET_SECONDS) -> None:
        self._max_points = max(1, min(MAX_POINTS, window_seconds // BUCKET_SECONDS))
        self._points: deque[HistoryPoint] = deque(maxlen=self._max_points)

    def record(self, state: ClusterState) -> None:
        point = make_point(state)
        if self._points and self._points[-1].t >= point.t:
            if self._points[-1].t == point.t:
                self._points[-1] = point
            return  # a clock step backwards: keep what we have
        self._points.append(point)
        oldest_allowed = point.t - (self._max_points - 1) * BUCKET_SECONDS
        while self._points and self._points[0].t < oldest_allowed:
            self._points.popleft()

    def points(self) -> list[HistoryPoint]:
        return list(self._points)
