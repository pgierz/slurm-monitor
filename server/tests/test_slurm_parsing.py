"""Tolerant parsing of slurmrestd values in their older and newer forms."""

import pytest

from slurm_monitor_server.slurm_parsing import (
    expand_hostlist,
    parse_gres,
    parse_index_list,
    parse_int,
    parse_number,
    parse_state_flags,
    parse_timestamp,
    parse_tres_count,
)
from slurm_monitor_server.synthetic import compress_hostlist


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (5, 5),
        (5.0, 5),
        ("5", 5),
        ({"set": True, "infinite": False, "number": 5}, 5),
        ({"set": False, "infinite": False, "number": 0}, None),
        ({"set": True, "infinite": True, "number": 0}, None),
        ({"number": 7}, 7),
        (None, None),
        (True, None),
        ("UNLIMITED", None),
        (0xFFFFFFFF, None),
        (0xFFFFFFFE, None),
        ([], None),
    ],
)
def test_parse_int_accepts_both_forms(raw, expected):
    assert parse_int(raw) == expected


def test_parse_number_tells_infinite_from_unset():
    assert parse_number({"set": False, "infinite": True, "number": 0}).infinite
    assert parse_number(0xFFFFFFFF).infinite
    assert parse_number("INFINITE").infinite
    unset = parse_number({"set": False, "infinite": False, "number": 0})
    assert not unset.infinite and not unset.is_set


def test_parse_timestamp_treats_zero_as_unknown():
    assert parse_timestamp(0) is None
    assert parse_timestamp({"set": True, "infinite": False, "number": 0}) is None
    assert parse_timestamp({"set": True, "infinite": False, "number": 1790000000}) == 1790000000
    assert parse_timestamp(1790000000) == 1790000000


@pytest.mark.parametrize(
    ("raws", "expected"),
    [
        ((["IDLE", "DRAIN"],), ["IDLE", "DRAIN"]),
        (("RUNNING",), ["RUNNING"]),
        (("idle", ["DRAIN"]), ["IDLE", "DRAIN"]),
        (("idle+drain",), ["IDLE", "DRAIN"]),
        (("mixed*",), ["MIXED", "NOT_RESPONDING"]),
        ((None,), []),
        ((["PENDING"], None), ["PENDING"]),
    ],
)
def test_parse_state_flags(raws, expected):
    assert parse_state_flags(*raws) == expected


def test_parse_gres_node_forms():
    (entry,) = parse_gres("gpu:a100:4")
    assert (entry.name, entry.type, entry.count, entry.indices) == ("gpu", "a100", 4, None)
    (entry,) = parse_gres("gpu:a100:4(S:0-1)")
    assert (entry.type, entry.count, entry.indices) == ("a100", 4, None)
    (entry,) = parse_gres("gpu:a100:3(IDX:0-2)")
    assert (entry.count, entry.indices) == (3, (0, 1, 2))
    (entry,) = parse_gres("gpu:a100:0(IDX:N/A)")
    assert (entry.count, entry.indices) == (0, ())
    (entry,) = parse_gres("gpu:4")
    assert (entry.type, entry.count) == ("", 4)
    (entry,) = parse_gres("gpu")
    assert (entry.type, entry.count) == ("", 1)


def test_parse_gres_several_entries_and_commas_inside_parentheses():
    entries = parse_gres("gpu:a40:1(IDX:0),gpu:A100:2(IDX:1,3),lustre:1")
    assert [(e.name, e.type, e.count, e.indices) for e in entries] == [
        ("gpu", "a40", 1, (0,)),
        ("gpu", "a100", 2, (1, 3)),
        ("lustre", "", 1, None),
    ]


def test_parse_gres_job_forms():
    assert parse_gres("gres/gpu:a100:2")[0].count == 2
    assert parse_gres("gres/gpu:a100:2")[0].type == "a100"
    assert parse_gres("gres:gpu:2")[0].count == 2
    assert parse_gres("gres/gpu=2")[0].count == 2
    assert parse_gres("") == []
    assert parse_gres(None) == []
    assert parse_gres("(null)") == []


def test_parse_index_list():
    assert parse_index_list("0-2,5") == [0, 1, 2, 5]
    assert parse_index_list("3") == [3]
    assert parse_index_list("N/A") == []


def test_parse_tres_count():
    text = "cpu=64,mem=10G,node=1,billing=64,gres/gpu=2,gres/gpu:a100=2"
    assert parse_tres_count(text, "gres/gpu") == 2
    assert parse_tres_count(text, "cpu") == 64
    assert parse_tres_count(text, "gres/fpga") is None
    assert parse_tres_count(None, "cpu") is None


def test_expand_hostlist():
    assert expand_hostlist("prod-[001-003,007],gpu-001") == [
        "prod-001", "prod-002", "prod-003", "prod-007", "gpu-001",
    ]  # fmt: skip
    assert expand_hostlist("smp-012") == ["smp-012"]
    assert expand_hostlist("n[1-2]x[1-2]") == ["n1x1", "n1x2", "n2x1", "n2x2"]
    assert expand_hostlist("") == []
    assert expand_hostlist(None) == []


def test_hostlist_round_trip():
    hosts = ["prod-001", "prod-002", "prod-004", "gpu-005"]
    assert compress_hostlist(hosts) == "prod-[001-002,004],gpu-005"
    assert expand_hostlist(compress_hostlist(hosts)) == hosts
