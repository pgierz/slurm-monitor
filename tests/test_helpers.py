from slurm_monitor.collectors._helpers import (
    as_float,
    as_int,
    as_str_list,
    first_present,
    safe_iter,
)
from slurm_monitor.collectors.jobs import _gpu_count_from_tres
from slurm_monitor.collectors.nodes import _gpu_breakdown


def test_as_int_handles_dict_and_scalar():
    assert as_int(5) == 5
    assert as_int("7") == 7
    assert as_int({"number": 3}) == 3
    assert as_int({"set": False, "number": 9}) == 9
    assert as_int({"set": True, "infinite": False}) == 0
    assert as_int(None, default=42) == 42
    assert as_int("not-a-number", default=-1) == -1


def test_as_float_dict_and_scalar():
    assert as_float({"number": "1.5"}) == 1.5
    assert as_float(2) == 2.0
    assert as_float(None) == 0.0


def test_as_str_list_drift_forms():
    assert as_str_list(["IDLE", "PLANNED"]) == ["IDLE", "PLANNED"]
    assert as_str_list("ALLOCATED+DRAIN") == ["ALLOCATED", "DRAIN"]
    assert as_str_list("DOWN,DRAIN") == ["DOWN", "DRAIN"]
    assert as_str_list(None) == []


def test_first_present_skips_none():
    d = {"a": None, "b": 0, "c": "x"}
    assert first_present(d, "a", "b", "c") == 0
    assert first_present(d, "a", "missing", default="dflt") == "dflt"


def test_safe_iter_filters_non_dicts():
    assert list(safe_iter([{"a": 1}, "skip", None, {"b": 2}])) == [{"a": 1}, {"b": 2}]
    assert list(safe_iter("not a list")) == []


def test_gpu_breakdown_parses_models():
    assert _gpu_breakdown("gpu:a100:4") == {"a100": 4}
    assert _gpu_breakdown("gpu:a40:1") == {"a40": 1}
    # Mixed nodes (rare on Albedo, but the parser supports it).
    assert _gpu_breakdown("gpu:a100:2,gpu:a40:1") == {"a100": 2, "a40": 1}
    # Bare gpu:N (no model) becomes "unknown".
    assert _gpu_breakdown("gpu:4") == {"unknown": 4}
    assert _gpu_breakdown("") == {}


def test_gpu_count_from_tres_string():
    assert _gpu_count_from_tres("cpu=4,mem=16G,gres/gpu=2") == 2
    assert _gpu_count_from_tres("cpu=8,mem=32G") == 0
    assert _gpu_count_from_tres("gres/gpu:a100=4") == 4
    assert _gpu_count_from_tres(None) == 0
