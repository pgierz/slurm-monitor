"""The HTTP interface against a mocked slurmrestd."""

from __future__ import annotations

import asyncio

import pytest

from slurm_monitor_server.gpu_metrics import GpuMetricsError
from slurm_monitor_server.poller import Poller, SnapshotStore
from slurm_monitor_server.slurmrestd import SlurmrestdClient, SlurmTokenProvider
from synthetic_cluster import BUSY_USER, NOW, SLURM_TOKEN, STATIC_TOKEN, Harness, make_settings

FAMILIES = ("queue", "nodes", "qos", "gpu", "runners")


async def test_family_endpoints_answer_503_before_the_first_poll():
    harness = Harness()
    async with harness.client() as client:
        for family in FAMILIES:
            response = await client.get(f"/api/v1/{family}")
            assert response.status_code == 503
            assert response.json() == {"error": "no_data"}
        health = (await client.get("/api/v1/health")).json()
    assert health["last_poll_at"] is None and health["last_poll_ok"] is False


async def test_failed_first_poll_still_answers_503():
    harness = Harness()
    harness.slurmrestd.failing = True
    assert not await harness.poll()
    async with harness.client() as client:
        assert (await client.get("/api/v1/queue")).status_code == 503
        health = (await client.get("/api/v1/health")).json()
    assert health["last_poll_at"] == "2026-10-01T12:32:07Z" and health["last_poll_ok"] is False


async def test_static_token_authentication():
    harness = Harness()
    await harness.poll()
    async with harness.client(token=None) as client:
        for path in ("queue", "nodes", "qos", "gpu", "runners", "me"):
            response = await client.get(f"/api/v1/{path}")
            assert response.status_code == 401
            assert response.json() == {"error": "unauthorized"}
        assert (await client.get("/api/v1/health")).status_code == 200
        assert (await client.get("/api/v1/auth/config")).status_code == 200
        for header in ("Bearer wrong", f"Basic {STATIC_TOKEN}", "Bearer", STATIC_TOKEN):
            response = await client.get("/api/v1/queue", headers={"Authorization": header})
            assert response.status_code == 401, header
        response = await client.get(
            "/api/v1/queue", headers={"Authorization": f"bearer {STATIC_TOKEN}"}
        )
        assert response.status_code == 200


async def test_several_static_tokens_and_no_method_enabled():
    settings = make_settings(auth={"static": {"enabled": True, "tokens": ["one", "two", ""]}})
    harness = Harness(settings=settings)
    await harness.poll()
    for token, expected in (("one", 200), ("two", 200), ("three", 401), ("", 401)):
        async with harness.client(token=None) as client:
            response = await client.get(
                "/api/v1/nodes", headers={"Authorization": f"Bearer {token}"}
            )
            assert response.status_code == expected, token

    closed = Harness(settings=make_settings(auth={}))
    await closed.poll()
    async with closed.client() as client:
        assert (await client.get("/api/v1/nodes")).status_code == 401
        assert (await client.get("/api/v1/auth/config")).json() == {"methods": [], "oidc": None}


async def test_health_auth_config_and_me_with_static_token():
    harness = Harness()
    await harness.poll()
    async with harness.client() as client:
        assert (await client.get("/api/v1/health")).json() == {
            "status": "ok", "version": "1.0.0", "schema_version": 1,
            "last_poll_at": "2026-10-01T12:32:07Z", "last_poll_ok": True,
        }  # fmt: skip
        assert (await client.get("/api/v1/auth/config")).json() == {
            "methods": ["token"], "oidc": None,
        }  # fmt: skip
        assert (await client.get("/api/v1/me")).json() == {
            "method": "token", "subject": "static-token", "username": None,
        }  # fmt: skip


async def test_envelope_and_stale_behaviour():
    harness = Harness()
    await harness.poll()
    async with harness.client() as client:
        first = (await client.get("/api/v1/queue")).json()
        assert first["schema_version"] == 1
        assert first["cluster"] == "synthetic"
        assert first["generated_at"] == "2026-10-01T12:32:07Z"
        assert first["stale"] is False

        harness.slurmrestd.failing = True
        harness.clock.now = NOW + 60
        assert not await harness.poll()
        stale = (await client.get("/api/v1/queue")).json()
        # The old snapshot is served, marked stale, with the time of its own poll.
        assert stale["stale"] is True
        assert stale["generated_at"] == first["generated_at"]
        assert stale["data"] == first["data"]
        health = (await client.get("/api/v1/health")).json()
        assert health["last_poll_ok"] is False
        assert health["last_poll_at"] == "2026-10-01T12:33:07Z"

        harness.slurmrestd.failing = False
        harness.clock.now = NOW + 120
        assert await harness.poll()
        fresh = (await client.get("/api/v1/queue")).json()
        assert fresh["stale"] is False
        assert fresh["generated_at"] == "2026-10-01T12:34:07Z"


@pytest.mark.parametrize("form", ["wrapped", "plain"])
async def test_synthetic_cluster_through_both_api_versions(form):
    harness = Harness(form)
    assert await harness.poll()
    async with harness.client() as client:
        queue = (await client.get("/api/v1/queue")).json()["data"]
        nodes = (await client.get("/api/v1/nodes")).json()["data"]
        qos = (await client.get(f"/api/v1/qos?user={BUSY_USER}")).json()["data"]
        gpu = (await client.get("/api/v1/gpu")).json()["data"]
        runners = (await client.get("/api/v1/runners")).json()["data"]

    assert queue["running"] > 300 and queue["pending"] > 50
    assert queue["mine"] is None and queue["my_jobs"] == []
    assert nodes["total"] == 240
    assert nodes["total"] == sum(nodes[key] for key in ("allocated", "idle", "drained", "down"))
    assert [p["name"] for p in nodes["partitions"]] == ["mpp", "smp", "fat", "gpu"]
    assert [p["total"] for p in nodes["partitions"]] == [170, 54, 10, 8]
    assert (gpu["total"], gpu["metrics_available"]) == (24, False)
    assert {t["type"]: t["total"] for t in gpu["types"]} == {"a100": 16, "a40": 8}
    assert runners["ci"]["runners_alive"] == 4 and runners["ci"]["jobs_waiting"] == 7
    assert runners["jupyterhub"]["sessions"] == 23 and runners["jupyterhub"]["with_gpu"] == 4
    assert [c["id"] for c in runners["dask"]["clusters"]] == ["a3f1", "b7c2", "carol"]
    assert runners["extra"] == [{"key": "matlab", "label": "MATLAB", "running": 3, "pending": 0}]
    assert qos["account"] == "hpc"
    # v0.0.38 has no shares endpoint: fairshare degrades to null.
    assert qos["fairshare"] == (0.42 if form == "wrapped" else None)
    assert "unused" not in [entry["name"] for entry in qos["qos"]]
    cpus = [entry["cpus_in_use"] for entry in qos["qos"]]
    assert cpus == sorted(cpus, reverse=True)


async def test_request_filters():
    harness = Harness()
    await harness.poll()
    async with harness.client() as client:

        async def data(path: str) -> dict:
            response = await client.get(path)
            assert response.status_code == 200
            return response.json()["data"]

        everything = await data("/api/v1/queue")
        by_partition = {
            name: await data(f"/api/v1/queue?partition={name}")
            for name in ("mpp", "smp", "fat", "gpu")
        }
        assert all(by_partition[name]["partition"] == name for name in by_partition)
        assert sum(q["running"] for q in by_partition.values()) == everything["running"]
        # Waiting jobs that name two partitions count in both.
        assert sum(q["pending"] for q in by_partition.values()) > everything["pending"]

        by_qos = [
            await data(f"/api/v1/queue?qos={name}") for name in ("30min", "12h", "48h", "1wk")
        ]
        assert sum(q["running"] for q in by_qos) == everything["running"]
        assert sum(q["pending"] for q in by_qos) == everything["pending"]

        mine = await data(f"/api/v1/queue?user={BUSY_USER}")
        assert mine["user"] == BUSY_USER
        assert mine["running"] == everything["running"]
        assert mine["my_jobs_total"] == mine["mine"]["running"] + mine["mine"]["pending"]
        assert mine["my_jobs_total"] > 20 and len(mine["my_jobs"]) == 20
        assert all(entry["state"] == "R" for entry in mine["my_jobs"])
        elapsed = [entry["elapsed_seconds"] for entry in mine["my_jobs"]]
        assert elapsed == sorted(elapsed, reverse=True)

        narrowed = await data(f"/api/v1/queue?user={BUSY_USER}&partition=gpu&qos=12h")
        assert narrowed["my_jobs_total"] < mine["my_jobs_total"]
        assert all(entry["partition"] == "gpu" for entry in narrowed["my_jobs"])

        nobody = await data("/api/v1/queue?user=nobody-here")
        assert nobody["mine"] == {"running": 0, "pending": 0} and nobody["my_jobs"] == []
        blank = await data("/api/v1/queue?user=&partition=")
        assert blank["mine"] is None and blank["partition"] is None

        gpu_nodes = await data("/api/v1/nodes?partition=gpu")
        assert gpu_nodes["total"] == 8 and len(gpu_nodes["partitions"]) == 1
        smp_nodes = await data("/api/v1/nodes?partition=smp")
        assert smp_nodes["total"] == 54
        assert any(n["name"] == "fat-001" for n in smp_nodes["partitions"][0]["nodes"])

        dask = (await data(f"/api/v1/runners?user={BUSY_USER}"))["dask"]["clusters"]
        assert [(c["id"], c["owner"]) for c in dask] == [("a3f1", BUSY_USER)]
        assert (dask[0]["workers_running"], dask[0]["workers_requested"]) == (14, 16)

        without_user = await data("/api/v1/qos")
        assert (without_user["user"], without_user["account"], without_user["fairshare"]) == (
            None, None, None,
        )  # fmt: skip


async def test_user_star_means_no_particular_user_with_the_static_token():
    harness = Harness()
    await harness.poll()
    async with harness.client() as client:

        async def data(path: str) -> dict:
            response = await client.get(path)
            assert response.status_code == 200
            return response.json()["data"]

        # With the static token '*' and an absent parameter give the same answer.
        for family in ("queue", "qos", "runners"):
            assert await data(f"/api/v1/{family}?user=*") == await data(f"/api/v1/{family}")
        queue = await data("/api/v1/queue?user=*&partition=mpp")
        assert (queue["user"], queue["mine"], queue["my_jobs"]) == (None, None, [])
        assert queue["my_jobs_total"] == 0 and queue["partition"] == "mpp"
        assert (await data("/api/v1/queue?user=%2A"))["mine"] is None


async def test_slurmrestd_requests_and_wrong_slurm_token():
    harness = Harness()
    await harness.poll()
    assert harness.slurmrestd.requests == [
        "/slurm/v0.0.40/jobs",
        "/slurm/v0.0.40/partitions",
        "/slurm/v0.0.40/nodes",
        "/slurmdb/v0.0.40/qos",
        "/slurm/v0.0.40/shares",
    ]
    wrong = Harness(settings=make_settings(slurm={
        "base_url": "https://slurm.example.org:6820", "user_name": "monitor", "token": "expired",
    }))  # fmt: skip
    assert not await wrong.poll()


async def test_separate_slurmdb_version():
    settings = make_settings()
    settings.slurm.db_api_version = "v0.0.39"
    harness = Harness(settings=settings)
    # The mock knows only v0.0.40: the qos request fails, the poll does not.
    assert await harness.poll()
    assert "/slurmdb/v0.0.39/qos" in harness.slurmrestd.requests
    async with harness.client() as client:
        qos = (await client.get("/api/v1/qos")).json()["data"]["qos"]
    assert qos and all(entry["cpu_limit"] is None for entry in qos)


async def test_gpu_metrics_from_the_synthetic_source_and_a_failing_source():
    harness = Harness(with_gpu_metrics=True)
    await harness.poll()
    async with harness.client() as client:
        gpu = (await client.get("/api/v1/gpu")).json()["data"]
    assert gpu["metrics_available"] is True
    states = {card["state"] for node in gpu["nodes"] for card in node["cards"]}
    assert "busy" in states and "idle_allocated" in states and "allocated" not in states
    idle = sum(c["state"] == "idle_allocated" for n in gpu["nodes"] for c in n["cards"])
    assert gpu["idle_allocated"] == idle
    assert gpu["history"][-1]["utilisation"] is not None

    class Broken:
        provides_metrics = True

        async def read(self, nodes):
            raise GpuMetricsError("exporter unreachable")

        async def close(self):
            return None

    broken = Harness(metrics_source=Broken())
    assert await broken.poll()  # the poll itself succeeds
    async with broken.client() as client:
        response = (await client.get("/api/v1/gpu")).json()
    assert response["stale"] is False
    assert response["data"]["metrics_available"] is False
    assert response["data"]["idle_allocated"] is None
    assert response["data"]["allocated"] == gpu["allocated"]


async def test_prometheus_endpoint_is_off_by_default_and_small_when_on():
    harness = Harness()
    await harness.poll()
    async with harness.client(token=None) as client:
        assert (await client.get("/metrics")).status_code == 404

    enabled = Harness(settings=make_settings(metrics={"enabled": True}))
    async with enabled.client(token=None) as client:
        before = (await client.get("/metrics")).text
        assert "slurm_monitor_last_poll_ok 0" in before
        await enabled.poll()
        response = await client.get("/metrics")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    text = response.text
    assert "slurm_monitor_last_poll_ok 1" in text
    assert 'slurm_monitor_nodes{state="down"} 4' in text
    assert "slurm_monitor_gpu_cards 24" in text
    assert 'slurm_monitor_jobs{state="running"}' in text


async def test_background_poller_task_polls_and_stops():
    harness = Harness()
    store = SnapshotStore(3600)
    poller = Poller(
        harness.settings,
        SlurmrestdClient(harness.settings.slurm, transport=harness.slurmrestd.transport()),
        harness.app.state.poller._metrics_source,
        store,
        harness.clock,
    )
    poller.start()
    for _ in range(100):
        if store.state is not None:
            break
        await asyncio.sleep(0.01)
    await poller.stop()
    assert store.state is not None and store.last_poll_ok


async def test_slurm_token_file_is_read_on_every_poll(tmp_path):
    token_file = tmp_path / "slurm.jwt"
    token_file.write_text("SLURM_JWT=old-token\n")
    settings = make_settings(slurm={
        "base_url": "https://slurm.example.org:6820", "user_name": "monitor",
        "token_file": str(token_file),
    })  # fmt: skip
    harness = Harness(settings=settings)
    assert not await harness.poll()  # the mock wants another token
    token_file.write_text(SLURM_TOKEN + "\n")  # the cron job rotates the file
    assert await harness.poll()
    token_file.unlink()
    assert not await harness.poll()
    async with harness.client() as client:
        assert (await client.get("/api/v1/nodes")).json()["stale"] is True


async def test_slurm_token_command():
    settings = make_settings().slurm
    settings.token = None
    settings.token_command = "/bin/echo SLURM_JWT=from-command"
    provider = SlurmTokenProvider(settings)
    assert await provider.token() == "from-command"
    settings.token_command = "/bin/echo SLURM_JWT=second"
    assert await provider.token() == "from-command"  # reused within its lifetime
    provider.forget_command_token()
    assert await provider.token() == "second"
