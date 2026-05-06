"""Helpers for tolerating slurmrestd schema drift across 22.x minor versions.

Field shapes change (sometimes ``{"number": 4}`` vs scalar ``4``); we centralise
the lookup so collectors don't have to care.
"""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any


def as_int(value: Any, default: int = 0) -> int:
    if value is None:
        return default
    if isinstance(value, dict):
        for key in ("number", "value", "infinite", "set"):
            if key in value:
                v = value[key]
                if isinstance(v, bool):
                    continue
                try:
                    return int(v)
                except (TypeError, ValueError):
                    return default
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def as_float(value: Any, default: float = 0.0) -> float:
    if value is None:
        return default
    if isinstance(value, dict):
        for key in ("number", "value"):
            if key in value:
                try:
                    return float(value[key])
                except (TypeError, ValueError):
                    return default
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def as_str_list(value: Any) -> list[str]:
    """Normalise a slurmrestd state field to a list of strings.

    Newer plugins return ``["IDLE", "PLANNED"]``; older plugins return a
    bitmask integer or a single string like ``"ALLOCATED+DRAIN"``.
    """

    if value is None:
        return []
    if isinstance(value, list):
        return [str(v) for v in value if v is not None]
    if isinstance(value, str):
        return [s for s in value.replace("+", ",").split(",") if s]
    return [str(value)]


def first_present(d: dict[str, Any], *keys: str, default: Any = None) -> Any:
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    return default


def safe_iter(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, list):
        return [v for v in value if isinstance(v, dict)]
    return []
