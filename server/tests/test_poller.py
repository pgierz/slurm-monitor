"""The poller: API version detection, optional payloads, back-off, work off the event loop."""

from __future__ import annotations

import asyncio
import logging
import threading

import pytest

from slurm_monitor_server import poller as poller_module
from slurm_monitor_server import slurmrestd as slurmrestd_module
from slurm_monitor_server.poller import poll_delay
from slurm_monitor_server.slurmrestd import detect_versions
from synthetic_cluster import NOW, Harness, make_settings

AUTO = {"base_url": "https://slurm.example.org:6820", "user_name": "monitor",
        "token": "slurm-jwt-for-tests"}  # fmt: skip


def auto_harness(**slurm) -> Harness:
    """A server without a configured API version."""
    return Harness(settings=make_settings(slurm={**AUTO, **slurm}))


async def health(harness: Harness) -> dict:
    async with harness.client() as client:
        return (await client.get("/api/v1/health")).json()


# ----- API version -------------------------------------------------------------


def test_detect_versions_takes_the_newest_per_plugin():
    openapi = {"paths": {
        "/slurm/v0.0.39/jobs": {}, "/slurm/v0.0.41/jobs": {}, "/slurm/v0.0.40/nodes": {},
        "/slurmdb/v0.0.40/qos": {}, "/slurm/v0.0.9/jobs": {}, "/openapi/v3": {},
    }}  # fmt: skip
    assert detect_versions(openapi) == {"slurm": "v0.0.41", "slurmdb": "v0.0.40"}
    for nothing in ({}, {"paths": []}, {"paths": {"/other": {}}}, None, [1]):
        assert detect_versions(nothing) == {}


async def test_api_version_is_detected_when_not_configured(caplog):
    harness = auto_harness()
    assert (await health(harness))["slurm_api_version"] is None  # not yet known
    with caplog.at_level(logging.INFO, logger="slurm_monitor_server.slurmrestd"):
        assert await harness.poll()
        assert await harness.poll()
    requests = harness.slurmrestd.requests
    # The document is read once, before the first poll; the older version it
    # also names is not used.
    assert requests[0] == "/openapi/v3" and requests.count("/openapi/v3") == 1
    assert requests[1:6] == [
        "/slurm/v0.0.40/jobs", "/slurm/v0.0.40/partitions", "/slurm/v0.0.40/nodes",
        "/slurmdb/v0.0.40/qos", "/slurm/v0.0.40/shares",
    ]  # fmt: skip
    assert (await health(harness))["slurm_api_version"] == "v0.0.40"
    chosen = [r.getMessage() for r in caplog.records if "API version" in r.getMessage()]
    assert chosen == ["slurmrestd API version v0.0.40 (slurmdb v0.0.40), detected from /openapi/v3"]


@pytest.mark.parametrize("location", ["/openapi.json", "/openapi"])
async def test_openapi_document_is_looked_for_in_three_places(location):
    harness = auto_harness()
    harness.slurmrestd.openapi_path = location
    assert await harness.poll()
    tried = [path for path in harness.slurmrestd.requests if "openapi" in path]
    assert tried == ["/openapi/v3", "/openapi.json", "/openapi"][: len(tried)]
    assert tried[-1] == location


async def test_configured_versions_are_used_as_given():
    harness = Harness()  # api_version = "v0.0.40" in the settings
    assert await harness.poll()
    assert not any("openapi" in path for path in harness.slurmrestd.requests)
    # Only the slurmdb version fixed: the other one is still detected.
    mixed = auto_harness(db_api_version="v0.0.39")
    assert await mixed.poll()
    assert "/slurm/v0.0.40/jobs" in mixed.slurmrestd.requests
    assert "/slurmdb/v0.0.39/qos" in mixed.slurmrestd.requests


async def test_failed_detection_fails_the_poll_and_is_tried_again(caplog):
    harness = auto_harness()
    harness.slurmrestd.openapi_path = "/elsewhere"
    with caplog.at_level(logging.WARNING):
        assert not await harness.poll()
    assert "set slurm.api_version" in caplog.text
    harness.slurmrestd.openapi_path = "/openapi/v3"
    assert await harness.poll()


async def test_version_is_detected_again_after_repeated_404s():
    harness = auto_harness()
    assert await harness.poll()
    # A Slurm upgrade: the version in use is gone, a newer one is offered.
    harness.slurmrestd.older_versions = ["v0.0.41"]
    harness.slurmrestd.version = lambda: "v0.0.42"
    for _ in range(3):
        assert not await harness.poll()
        assert harness.slurmrestd.requests.count("/openapi/v3") == 1
    assert (await health(harness))["slurm_api_version"] is None
    assert await harness.poll()
    assert harness.slurmrestd.requests.count("/openapi/v3") == 2
    assert harness.slurmrestd.requests[-1] == "/slurm/v0.0.42/shares"
    assert (await health(harness))["slurm_api_version"] == "v0.0.42"

    # A configured version is never replaced, however often it answers 404.
    fixed = Harness()
    fixed.slurmrestd.version = lambda: "v0.0.42"
    for _ in range(5):
        assert not await fixed.poll()
    assert not any("openapi" in path for path in fixed.slurmrestd.requests)
    assert (await health(fixed))["slurm_api_version"] == "v0.0.40"


# ----- optional payloads -------------------------------------------------------


async def qos_view(harness: Harness) -> dict:
    async with harness.client() as client:
        return (await client.get("/api/v1/qos?user=alice")).json()


@pytest.mark.parametrize("failure", ["http_500", "errors_in_a_200"])
async def test_last_good_qos_and_shares_are_kept_when_their_fetch_fails(failure, caplog):
    harness = Harness()
    assert await harness.poll()
    good = (await qos_view(harness))["data"]
    assert good["fairshare"] == 0.42 and any(e["cpu_limit"] for e in good["qos"])

    broken = harness.slurmrestd.failing_paths if failure == "http_500" else (
        harness.slurmrestd.reporting_errors
    )  # fmt: skip
    broken.update({"/slurmdb/v0.0.40/qos", "/slurm/v0.0.40/shares"})
    with caplog.at_level(logging.INFO, logger="slurm_monitor_server.poller"):
        for step in (1, 2, 3):
            harness.clock.now = NOW + 60 * step
            assert await harness.poll()  # the poll itself succeeds
        answer = await qos_view(harness)
        assert answer["stale"] is False and answer["generated_at"] == "2026-10-01T12:35:07Z"
        kept = answer["data"]
        assert kept["fairshare"] == 0.42 and kept["account"] == good["account"]
        assert [(e["name"], e["cpu_limit"], e["max_wall_seconds"]) for e in kept["qos"]] == [
            (e["name"], e["cpu_limit"], e["max_wall_seconds"]) for e in good["qos"]
        ]
        # One warning per payload for three failing polls, …
        warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
        assert sorted(r.getMessage().split(" ")[0] for r in warnings) == ["qos", "shares"]
        # … and one line each when they work again.
        broken.clear()
        assert await harness.poll() and await harness.poll()
    again = [r.getMessage() for r in caplog.records if "available again" in r.getMessage()]
    assert sorted(again) == ["qos available again", "shares available again"]


async def test_never_available_optional_payloads_warn_once_and_give_null(caplog):
    harness = Harness("plain")  # v0.0.38: no shares endpoint
    with caplog.at_level(logging.WARNING, logger="slurm_monitor_server.poller"):
        for _ in range(3):
            assert await harness.poll()
    assert [r.getMessage().split(" ")[0] for r in caplog.records] == ["shares"]
    assert (await qos_view(harness))["data"]["fairshare"] is None


async def test_errors_in_a_200_answer_of_a_required_payload_fail_the_poll():
    harness = Harness()
    assert await harness.poll()
    harness.slurmrestd.reporting_errors.add("/slurm/v0.0.40/nodes")
    assert not await harness.poll()
    assert (await qos_view(harness))["stale"] is True
    # An empty errors array, as every good answer carries, is no failure.
    harness.slurmrestd.reporting_errors.clear()
    assert await harness.poll()


# ----- back-off ----------------------------------------------------------------


def test_poll_delay_doubles_up_to_five_minutes():
    assert [poll_delay(60, n) for n in range(6)] == [60, 120, 240, 300, 300, 300]
    assert [poll_delay(15, n) for n in range(7)] == [15, 30, 60, 120, 240, 300, 300]
    # An interval above five minutes is never shortened.
    assert [poll_delay(600, n) for n in range(3)] == [600, 600, 600]
    assert poll_delay(60, 10_000) == 300


async def test_consecutive_failures_are_counted_and_reset_on_success():
    harness = Harness()
    poller = harness.app.state.poller
    harness.slurmrestd.failing = True
    for expected in (1, 2, 3):
        assert not await harness.poll()
        assert poller.consecutive_failures == expected
    harness.slurmrestd.failing = False
    assert await harness.poll()
    assert poller.consecutive_failures == 0


async def test_background_task_waits_longer_after_failures(monkeypatch):
    harness = Harness()
    harness.slurmrestd.failing = True
    poller = harness.app.state.poller
    delays: list[float] = []

    async def sleep(seconds: float) -> None:
        delays.append(round(seconds))
        if len(delays) == 4:
            harness.slurmrestd.failing = False
        if len(delays) == 6:
            raise asyncio.CancelledError

    monkeypatch.setattr(poller_module.asyncio, "sleep", sleep)
    with pytest.raises(asyncio.CancelledError):
        await poller.run()
    assert delays == [120, 240, 300, 300, 60, 60]


# ----- work off the event loop -------------------------------------------------


async def test_api_requests_are_answered_while_a_poll_parses_and_reduces(monkeypatch):
    harness = Harness()
    assert await harness.poll()
    started, release = threading.Event(), threading.Event()
    threads: dict[str, threading.Thread] = {}
    real_reduce, real_parse = poller_module.reduce_jobs, slurmrestd_module._parse_payload

    def slow_reduce(*arguments, **keywords):
        threads["reduce"] = threading.current_thread()
        started.set()
        assert release.wait(10)
        return real_reduce(*arguments, **keywords)

    def recording_parse(*arguments):
        threads["parse"] = threading.current_thread()
        return real_parse(*arguments)

    monkeypatch.setattr(poller_module, "reduce_jobs", slow_reduce)
    monkeypatch.setattr(slurmrestd_module, "_parse_payload", recording_parse)
    harness.clock.now = NOW + 60
    poll = asyncio.create_task(harness.poll())
    while not started.is_set():
        await asyncio.sleep(0.005)
    # The poll is in the middle of its reduction; the API still answers.
    async with harness.client() as client:
        for path in ("/api/v1/health", "/api/v1/queue", "/api/v1/gpu"):
            response = await asyncio.wait_for(client.get(path), timeout=5)
            assert response.status_code == 200
    assert not poll.done()
    release.set()
    assert await poll
    main = threading.main_thread()
    assert threads["reduce"] is not main and threads["parse"] is not main
