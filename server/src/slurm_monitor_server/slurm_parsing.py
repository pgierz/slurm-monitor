"""Tolerant helpers for slurmrestd JSON.

slurmrestd's payloads differ between API versions. Older plugins (v0.0.38 and
before) give plain numbers and single state strings; newer ones (v0.0.40 and
later) wrap many numbers as ``{"set": true, "infinite": false, "number": 5}``
and give states as lists of flags. Every helper here accepts both forms.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

# Slurm's NO_VAL / INFINITE sentinels as they appear when a plain-number
# plugin does not translate them.
_NO_VAL_SENTINELS = {0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFE, 0xFFFFFFFFFFFFFFFF}
_INFINITE_SENTINELS = {0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF}


@dataclass(frozen=True, slots=True)
class Number:
    """A Slurm number: a value, 'not set', or 'infinite'."""

    value: float | None
    infinite: bool = False

    @property
    def is_set(self) -> bool:
        return self.value is not None and not self.infinite


def parse_number(raw: Any) -> Number:
    """Read a number given plainly, as a string, or as a set/infinite/number object."""
    if raw is None or isinstance(raw, bool):
        return Number(None)
    if isinstance(raw, dict):
        if raw.get("infinite"):
            return Number(None, infinite=True)
        if raw.get("set") is False:
            return Number(None)
        return parse_number(raw.get("number"))
    if isinstance(raw, int | float):
        if raw in _INFINITE_SENTINELS:
            return Number(None, infinite=True)
        if raw in _NO_VAL_SENTINELS:
            return Number(None)
        return Number(float(raw))
    if isinstance(raw, str):
        text = raw.strip()
        if text.upper() in {"INFINITE", "UNLIMITED"}:
            return Number(None, infinite=True)
        try:
            return Number(float(text))
        except ValueError:
            return Number(None)
    return Number(None)


def parse_int(raw: Any) -> int | None:
    """An integer, or None when unset or infinite."""
    number = parse_number(raw)
    return int(number.value) if number.is_set and number.value is not None else None


def parse_float(raw: Any) -> float | None:
    number = parse_number(raw)
    return number.value if number.is_set else None


def parse_timestamp(raw: Any) -> int | None:
    """Unix seconds; zero and unset both mean 'not known'."""
    value = parse_int(raw)
    return value if value and value > 0 else None


def parse_text(raw: Any) -> str:
    """A string field; null and non-strings become the empty string."""
    if isinstance(raw, str):
        return raw
    if isinstance(raw, int | float) and not isinstance(raw, bool):
        return str(raw)
    return ""


def parse_state_flags(*raws: Any) -> list[str]:
    """Upper-case state flags from a list, a single string, or ``IDLE+DRAIN`` text.

    Several raw values may be given (older node payloads split the state over
    ``state`` and ``state_flags``); their flags are concatenated in order.
    """
    flags: list[str] = []
    for raw in raws:
        items: list[Any]
        if raw is None:
            continue
        if isinstance(raw, str):
            items = re.split(r"[+,\s]+", raw)
        elif isinstance(raw, list | tuple):
            items = list(raw)
        else:
            continue
        for item in items:
            if not isinstance(item, str):
                continue
            # sinfo-style suffixes (*, ~, #, !, %, $, @, ^, -) mark conditions
            # such as "not responding"; only '*' maps onto a flag we use.
            name = item.strip().upper()
            if not name:
                continue
            not_responding = name.endswith("*")
            name = name.rstrip("*~#!%$@^-")
            if name and name not in flags:
                flags.append(name)
            if not_responding and "NOT_RESPONDING" not in flags:
                flags.append("NOT_RESPONDING")
    return flags


def split_outside_parentheses(text: str, separator: str = ",") -> list[str]:
    """Split on a separator, ignoring separators inside parentheses or brackets."""
    parts: list[str] = []
    depth = 0
    current: list[str] = []
    for char in text:
        if char in "([":
            depth += 1
        elif char in ")]":
            depth = max(0, depth - 1)
        if char == separator and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(char)
    parts.append("".join(current))
    return [part.strip() for part in parts if part.strip()]


def parse_index_list(text: str) -> list[int]:
    """Expand ``0-2,5`` to ``[0, 1, 2, 5]``; anything unreadable gives ``[]``."""
    indices: list[int] = []
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        match = re.fullmatch(r"(\d+)(?:-(\d+))?", part)
        if not match:
            return []
        first = int(match.group(1))
        last = int(match.group(2)) if match.group(2) else first
        if last < first or last - first > 4096:
            return []
        indices.extend(range(first, last + 1))
    return indices


@dataclass(frozen=True, slots=True)
class GresEntry:
    """One entry of a GRES string such as ``gpu:a100:3(IDX:0-2)``."""

    name: str
    type: str  # lower-case; empty when the GRES has no type
    count: int
    indices: tuple[int, ...] | None  # None when no IDX list was given


_GRES_COUNT = re.compile(r"^(\d+)([KMGTP]?)$", re.IGNORECASE)
_GRES_MULTIPLIER = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4, "P": 1024**5}


def parse_gres(text: Any) -> list[GresEntry]:
    """Parse a node or job GRES string.

    Accepts ``gpu:a100:4``, ``gpu:4``, ``gpu``, ``gpu:a100:4(S:0-1)``,
    ``gpu:a100:3(IDX:0-2)``, ``gpu:a100:0(IDX:N/A)``, and the job forms with a
    ``gres/`` or ``gres:`` prefix (``gres/gpu:a100:2``, ``gres/gpu=2``).
    """
    if not isinstance(text, str) or not text.strip() or text.strip() in {"(null)", "N/A"}:
        return []
    entries: list[GresEntry] = []
    for part in split_outside_parentheses(text):
        indices: tuple[int, ...] | None = None
        for qualifier in re.findall(r"\(([^)]*)\)", part):
            if qualifier.upper().startswith("IDX:"):
                indices = tuple(parse_index_list(qualifier[4:]))
        body = re.sub(r"\([^)]*\)", "", part).strip()
        body = re.sub(r"^gres[/:]", "", body, flags=re.IGNORECASE)
        body = body.replace("=", ":")
        fields = [field for field in body.split(":") if field != ""]
        if not fields:
            continue
        name = fields[0].lower()
        gres_type = ""
        count = 1
        rest = fields[1:]
        if rest:
            count_match = _GRES_COUNT.match(rest[-1])
            if count_match:
                count = int(count_match.group(1)) * _GRES_MULTIPLIER[count_match.group(2).upper()]
                rest = rest[:-1]
            if rest:
                gres_type = ":".join(rest).lower()
        entries.append(GresEntry(name=name, type=gres_type, count=count, indices=indices))
    return entries


def parse_tres_count(text: Any, key: str) -> int | None:
    """Read one count from a TRES string such as ``cpu=64,mem=10G,gres/gpu=2``."""
    if not isinstance(text, str):
        return None
    for part in text.split(","):
        name, _, value = part.partition("=")
        if name.strip().lower() == key.lower():
            match = re.match(r"^\d+", value.strip())
            if match:
                return int(match.group(0))
    return None


def expand_hostlist(text: Any) -> list[str]:
    """Expand a Slurm host list such as ``prod-[001-003,007],gpu-001``.

    Covers one or more bracket groups per name; padding is kept.
    """
    if not isinstance(text, str) or not text.strip():
        return []
    hosts: list[str] = []
    for part in split_outside_parentheses(text):
        hosts.extend(_expand_one(part))
    return hosts


def _expand_one(pattern: str) -> list[str]:
    match = re.search(r"\[([^\]]*)\]", pattern)
    if not match:
        return [pattern]
    prefix, suffix = pattern[: match.start()], pattern[match.end() :]
    names: list[str] = []
    for item in match.group(1).split(","):
        item = item.strip()
        range_match = re.fullmatch(r"(\d+)-(\d+)", item)
        if range_match:
            width = len(range_match.group(1))
            first, last = int(range_match.group(1)), int(range_match.group(2))
            if last < first or last - first > 100_000:
                continue
            for value in range(first, last + 1):
                names.extend(_expand_one(f"{prefix}{value:0{width}d}{suffix}"))
        elif item:
            names.extend(_expand_one(f"{prefix}{item}{suffix}"))
    return names
