import json

import pytest

import dump_slurmrestd as dump


def num(n):
    return {"set": True, "infinite": False, "number": n}


def jobs_plain():
    """Older style: plain values."""
    return {
        "meta": {"client": {"source": "[login1.cluster.internal]:41234", "user": "jdoe"},
                 "slurm": {"cluster": "testcluster"}},
        "errors": [],
        "jobs": [
            {"job_id": 1001, "name": "echam_run_42", "user_name": "jdoe", "user_id": 5001,
             "group_name": "climate", "account": "paleo.dyn", "partition": "mpp",
             "qos": "12h", "job_state": "RUNNING", "state_reason": "None",
             "nodes": "prod-[001-016]", "node_count": 16, "cpus": 2048,
             "time_limit": 720, "start_time": 1790000000,
             "current_working_directory": "/home/jdoe/runs/exp42",
             "command": "/home/jdoe/runs/exp42/run.sh",
             "standard_output": "/home/jdoe/runs/exp42/slurm-%j.out",
             "standard_error": "/home/jdoe/runs/exp42/slurm-%j.err",
             "comment": "tuning run for jdoe", "mail_user": "jane.doe@awi.example",
             "tres_req_str": "cpu=2048,mem=4000G,node=16", "gres_detail": [],
             "flags": ["EXACT_CPU_COUNT_REQUESTED"],
             "mystery_field": "/work/jdoe/scratch", "note": "asked by jdoe, see mroe"},
            {"job_id": 1002, "name": "ci-12345", "user_name": "gitlab-runner",
             "account": "hpc", "partition": "smp", "qos": "30min",
             "job_state": "PENDING", "state_reason": "Priority", "nodes": "",
             "current_working_directory": "/tmp/ci", "command": "", "comment": "",
             "standard_output": "", "standard_error": ""},
            {"job_id": 1003, "name": "dask-gateway-mroe-scheduler", "user_name": "mroe",
             "account": "hpc", "partition": "smp", "qos": "12h", "job_state": "RUNNING",
             "state_reason": "None", "comment": "a3f1c0",
             "command": "/opt/dask/bin/dask-scheduler --port 0"},
            {"job_id": 1004, "name": "dask-gateway-mroe-w7", "user_name": "mroe",
             "account": "hpc", "partition": "smp", "qos": "12h", "job_state": "RUNNING",
             "state_reason": "None", "comment": "a3f1c0",
             "command": "/opt/dask/bin/dask-worker tcp://10.0.0.1:8786"},
            {"job_id": 1005, "name": "spawner-jupyterhub", "user_name": "jdoe",
             "account": "paleo.dyn", "partition": "gpu", "qos": "12h",
             "job_state": "RUNNING", "state_reason": "None",
             "tres_per_node": "gres/gpu:a100:1", "gres_detail": ["gpu:a100:1(IDX:0)"]},
            {"job_id": 1006, "name": "jupyterhub-mroe", "user_name": "mroe",
             "account": "hpc", "partition": "smp", "qos": "12h",
             "job_state": "PENDING", "state_reason": "QOSGrpCpuLimit"},
            {"job_id": 1007, "name": "echam_run_42", "user_name": "jdoe",
             "account": "paleo.dyn", "partition": "mpp", "qos": "12h",
             "job_state": "PENDING", "state_reason": "Resources"},
        ],
    }


def jobs_objects():
    """Newer style: {"set", "infinite", "number"} objects, list states, comment object."""
    return {
        "meta": {"client": {"source": "[login1]:1", "user": "jdoe"}},
        "jobs": [
            {"job_id": 2001, "name": "post_proc", "user_name": "jdoe", "user_id": 5001,
             "group_name": "climate", "account": "paleo.dyn", "partition": "gpu",
             "qos": "12h", "job_state": ["RUNNING"], "state_reason": "None",
             "nodes": "gpu-005", "node_count": num(1), "cpus": num(8),
             "time_limit": {"set": False, "infinite": True, "number": 0},
             "start_time": num(1790000000), "priority": num(4242),
             "current_working_directory": "/albedo/work/jdoe",
             "command": "/albedo/work/jdoe/pp.sh", "standard_output": "/albedo/work/jdoe/o",
             "standard_error": "/albedo/work/jdoe/e", "standard_input": "/dev/null",
             "comment": {"administrator": "", "job": "see ticket 12", "system": ""},
             "association": {"account": "paleo.dyn", "cluster": "testcluster",
                             "partition": "", "user": "jdoe", "id": 77},
             "tres_per_node": "gres/gpu:a100:2", "gres_detail": ["gpu:a100:2(IDX:0-1)"],
             "job_resources": {"nodes": {"count": 1, "list": "gpu-005"}}},
        ],
    }


def nodes_payload():
    return {"nodes": [
        {"name": "gpu-005", "hostname": "gpu-005", "address": "gpu-005",
         "state": ["MIXED", "DRAIN"], "partitions": ["gpu"], "gres": "gpu:a100:4",
         "gres_used": "gpu:a100:2(IDX:0-1)", "cpus": 64, "real_memory": 512000,
         "reason": "bad DIMM, reported by jdoe", "reason_set_by_user": "root",
         "owner": "", "features": ["a100", "nvme"], "tres": "cpu=64,mem=500G",
         "boot_time": num(1789000000), "free_mem": num(123456)},
    ]}


def partitions_payload():
    return {"partitions": [
        {"name": "mpp", "nodes": {"configured": "prod-[001-170]", "total": 170},
         "accounts": {"allowed": "paleo.dyn,hpc", "deny": ""},
         "groups": {"allowed": "climate"},
         "qos": {"allowed": "12h,30min", "deny": "", "assigned": ""},
         "partition": {"state": ["UP"]}, "maximums": {"time": num(2880)}},
    ]}


def qos_payload():
    return {"qos": [
        {"name": "12h", "description": "twelve hours", "id": 3, "flags": [],
         "limits": {"max": {"wall_clock": {"per": {"job": num(720)}},
                            "tres": {"total": [{"type": "cpu", "name": "", "id": 1,
                                                "count": 18000}]}}},
         "preempt": {"list": ["30min"], "mode": ["DISABLED"]}, "priority": num(10)},
    ]}


def shares_payload():
    return {"shares": {"total_shares": 1000, "shares": [
        {"id": 1, "cluster": "testcluster", "name": "root", "parent": "",
         "type": ["ASSOCIATION"], "fairshare": {"factor": 1.0, "level": 1.0}},
        {"id": 2, "cluster": "testcluster", "name": "paleo.dyn", "parent": "root",
         "type": ["ASSOCIATION"], "shares": num(10),
         "fairshare": {"factor": 0.5, "level": 0.6}},
        {"id": 3, "cluster": "testcluster", "name": "jdoe", "parent": "paleo.dyn",
         "partition": "", "type": ["USER"], "shares": num(1), "effective_usage": 0.12,
         "fairshare": {"factor": 0.42, "level": 0.9},
         "tres": {"run_seconds": [{"name": "cpu", "value": num(3600)}]}},
    ]}}


def all_payloads():
    return {"jobs": jobs_plain(), "nodes": nodes_payload(),
            "partitions": partitions_payload(), "qos": qos_payload(),
            "shares": shares_payload(), "openapi": {"paths": {}}}


def scrub_all(payloads=None, **kwargs):
    anonymiser = dump.Anonymiser(salt="test", **kwargs)
    result, residue = dump.anonymise_payloads(payloads or all_payloads(), anonymiser)
    return result, residue, anonymiser


def job(result, job_id):
    return [j for j in result["jobs"]["jobs"] if j["job_id"] == job_id][0]


SECRETS = ["jdoe", "mroe", "gitlab-runner", "paleo.dyn", "climate", "jane.doe",
           "awi.example", "/home/", "/work/", "exp42", "echam", "tuning",
           "login1", "a3f1c0"]


def test_no_secret_survives_plain_style():
    result, residue, _ = scrub_all()
    text = json.dumps(result)
    for secret in SECRETS:
        assert secret not in text, secret
    assert residue == {"partitions": [("partitions.accounts.allowed", "hpc")]} or residue == {}


def test_no_secret_survives_object_style():
    payloads = all_payloads()
    payloads["jobs"] = jobs_objects()
    result, residue, _ = scrub_all(payloads)
    text = json.dumps(result)
    for secret in ["jdoe", "paleo.dyn", "climate", "/albedo/", "post_proc", "ticket", "login1"]:
        assert secret not in text, secret
    assert residue == {}
    j = job(result, 2001)
    assert j["cpus"] == num(8)
    assert j["time_limit"] == {"set": False, "infinite": True, "number": 0}
    assert j["start_time"] == num(1790000000)
    assert j["job_state"] == ["RUNNING"]
    assert j["association"]["user"] == j["user_name"]
    assert j["association"]["account"] == j["account"]
    assert j["association"]["cluster"] == "testcluster"
    assert j["comment"]["job"].startswith("c-")
    assert j["comment"]["administrator"] == ""
    assert j["job_resources"]["nodes"]["list"] == "gpu-005"
    assert j["standard_input"].startswith("/scrubbed/path-")


def test_pseudonyms_are_stable_and_shaped():
    result, _, anonymiser = scrub_all()
    j1, j5, j7 = job(result, 1001), job(result, 1005), job(result, 1007)
    assert j1["user_name"] == j5["user_name"] == anonymiser.users["jdoe"]
    assert j1["user_name"].startswith("user") and len(j1["user_name"]) == 7
    assert j1["account"] == j5["account"] and j1["account"].startswith("acct")
    assert j1["name"] == j7["name"] and j1["name"].startswith("job") and len(j1["name"]) == 9
    # the same user and account in the shares payload
    rows = result["shares"]["shares"]["shares"]
    assert rows[2]["name"] == j1["user_name"]
    assert rows[2]["parent"] == rows[1]["name"] == j1["account"]
    assert rows[0]["name"] == "root" and rows[1]["parent"] == "root"
    assert rows[2]["tres"]["run_seconds"][0]["name"] == "cpu"
    assert rows[2]["fairshare"] == {"factor": 0.42, "level": 0.9}
    # and in the partition lists
    part = result["partitions"]["partitions"][0]
    assert part["accounts"]["allowed"] == "%s,%s" % (
        anonymiser.accounts["paleo.dyn"], anonymiser.accounts["hpc"])
    assert part["groups"]["allowed"] == j1["group_name"] == "group01"


def test_runner_names_keep_their_prefix():
    result, _, _ = scrub_all()
    assert job(result, 1002)["name"] == "ci-12345"
    assert job(result, 1005)["name"] == "spawner-jupyterhub"
    scheduler, worker = job(result, 1003)["name"], job(result, 1004)["name"]
    assert scheduler.startswith("dask-gateway-scheduler-")
    assert worker.startswith("dask-gateway-") and "scheduler" not in worker
    assert scheduler != worker
    assert job(result, 1006)["name"].startswith("jupyterhub-")
    for job_id in (1003, 1004, 1006):
        assert "mroe" not in job(result, job_id)["name"]
    assert "scheduler" in job(result, 1003)["command"]


def test_runner_patterns_are_configurable():
    result, _, _ = scrub_all(runner_patterns=[r"^echam"])
    assert job(result, 1001)["name"].startswith("echam-")
    assert job(result, 1002)["name"].startswith("job")


def test_comments_keep_presence_and_grouping():
    result, _, _ = scrub_all()
    assert job(result, 1002)["comment"] == ""
    assert job(result, 1003)["comment"] == job(result, 1004)["comment"]
    assert job(result, 1003)["comment"].startswith("c-")
    assert job(result, 1003)["comment"] != job(result, 1001)["comment"]


def test_paths_commands_and_mail():
    result, _, anonymiser = scrub_all()
    j = job(result, 1001)
    for key in ("current_working_directory", "standard_output", "standard_error"):
        assert j[key].startswith("/scrubbed/path-")
    assert j["standard_output"] != j["standard_error"]
    assert j["command"].startswith("/scrubbed/command-")
    assert j["mail_user"].endswith("@example.org")
    assert job(result, 1002)["standard_output"] == ""
    assert job(result, 1002)["command"] == ""


def test_unknown_fields_are_scrubbed():
    result, _, anonymiser = scrub_all()
    j = job(result, 1001)
    assert j["mystery_field"].startswith("/scrubbed/path-")
    assert j["note"] == "asked by %s, see %s" % (anonymiser.users["jdoe"],
                                                 anonymiser.users["mroe"])
    node = result["nodes"]["nodes"][0]
    assert node["reason"] == "bad DIMM, reported by %s" % anonymiser.users["jdoe"]
    assert anonymiser.free_text("see ~/x/y and /p/q/r.txt ok").count("/scrubbed/path-") == 2
    assert anonymiser.free_text("write to a.b@site.example") .endswith("@example.org")
    assert result["jobs"]["meta"]["client"]["source"] == "scrubbed"
    assert result["jobs"]["meta"]["client"]["user"] == anonymiser.users["jdoe"]


def test_cluster_facts_are_kept():
    before = all_payloads()
    result, _, _ = scrub_all()
    assert result["nodes"]["nodes"][0] == dict(
        before["nodes"]["nodes"][0], reason=result["nodes"]["nodes"][0]["reason"])
    assert result["qos"] == before["qos"]
    for old, new in zip(before["jobs"]["jobs"], result["jobs"]["jobs"]):
        for key in ("job_id", "partition", "qos", "job_state", "state_reason", "nodes",
                    "node_count", "cpus", "time_limit", "start_time", "user_id",
                    "tres_req_str", "tres_per_node", "gres_detail", "flags"):
            assert old.get(key) == new.get(key), key
    part = result["partitions"]["partitions"][0]
    assert part["name"] == "mpp" and part["nodes"]["configured"] == "prod-[001-170]"
    assert part["qos"]["allowed"] == "12h,30min"


def test_keep_user():
    result, residue, anonymiser = scrub_all(keep_users=["jdoe"])
    assert job(result, 1001)["user_name"] == "jdoe"
    assert job(result, 1003)["user_name"].startswith("user")
    assert job(result, 1001)["note"].startswith("asked by jdoe, see user")
    assert job(result, 1001)["current_working_directory"].startswith("/scrubbed/")
    assert "jobs" not in residue


def test_residue_reports_name_that_is_kept_elsewhere():
    payloads = all_payloads()
    payloads["jobs"]["jobs"][0]["account"] = "mpp"  # account named like a partition
    _, residue, _ = scrub_all(payloads)
    assert ("jobs.partition", "mpp") in residue["jobs"]


def test_input_is_not_modified():
    payloads = all_payloads()
    snapshot = json.dumps(payloads, sort_keys=True)
    scrub_all(payloads)
    assert json.dumps(payloads, sort_keys=True) == snapshot


def test_salt_changes_hashes_but_not_counters():
    a = dump.Anonymiser(salt="a")
    b = dump.Anonymiser(salt="b")
    assert a.comment("x") != b.comment("x")
    assert a.comment("x") == a.comment("x")
    assert a.user("u") == b.user("u") == "user001"


def test_detect_versions():
    openapi = {"paths": {"/slurm/v0.0.39/jobs": {}, "/slurm/v0.0.41/jobs": {},
                         "/slurm/v0.0.40/nodes": {}, "/slurmdb/v0.0.40/qos": {},
                         "/openapi/v3": {}}}
    assert dump.detect_versions(openapi) == {"slurm": "v0.0.41", "slurmdb": "v0.0.40"}
    assert dump.detect_versions({}) == {}
    assert dump.version_key("v0.0.9") < dump.version_key("v0.0.40")


def test_obtain_token():
    assert dump.obtain_token({"SLURM_JWT": " abc "}) == "abc"
    assert dump.obtain_token({}, run=lambda: "SLURM_JWT=eyJ.x.y\n") == "eyJ.x.y"
    with pytest.raises(RuntimeError):
        dump.obtain_token({}, run=lambda: "nothing")


class FakeClient(object):
    def __init__(self, responses):
        self.responses = responses
        self.requested = []

    def get(self, path):
        self.requested.append(path)
        if path not in self.responses:
            raise IOError("no such path")
        return self.responses[path]


def test_fetch_all_detects_version_and_survives_missing_endpoint():
    client = FakeClient({
        "/openapi.json": {"paths": {"/slurm/v0.0.40/jobs": {}, "/slurmdb/v0.0.40/qos": {}}},
        "/slurm/v0.0.40/jobs": jobs_plain(), "/slurm/v0.0.40/nodes": nodes_payload(),
        "/slurm/v0.0.40/partitions": partitions_payload(),
        "/slurmdb/v0.0.40/qos": qos_payload(),
    })
    payloads, statuses, versions = dump.fetch_all(client)
    assert client.requested[:2] == ["/openapi/v3", "/openapi.json"]
    assert versions == {"slurm": "v0.0.40", "slurmdb": "v0.0.40"}
    assert sorted(payloads) == ["jobs", "nodes", "openapi", "partitions", "qos"]
    assert statuses["shares"]["ok"] is False and statuses["jobs"]["ok"] is True


def test_fetch_all_needs_a_version():
    with pytest.raises(RuntimeError):
        dump.fetch_all(FakeClient({}))
    payloads, _, versions = dump.fetch_all(
        FakeClient({"/slurm/v0.0.38/jobs": jobs_plain()}), api_version="v0.0.38")
    assert versions["slurm"] == "v0.0.38" and "jobs" in payloads


def test_main_end_to_end(tmp_path, monkeypatch, capsys):
    responses = {
        "/openapi/v3": {"paths": {"/slurm/v0.0.41/jobs": {}, "/slurmdb/v0.0.41/qos": {}}},
        "/slurm/v0.0.41/jobs": jobs_objects(), "/slurm/v0.0.41/nodes": nodes_payload(),
        "/slurm/v0.0.41/partitions": partitions_payload(),
        "/slurmdb/v0.0.41/qos": qos_payload(), "/slurm/v0.0.41/shares": shares_payload(),
    }
    seen = {}

    def fake_client(base_url, user, token, timeout, ca_file):
        seen.update(base_url=base_url, user=user, token=token)
        return FakeClient(responses)

    monkeypatch.setattr(dump, "Client", fake_client)
    monkeypatch.setenv("SLURM_JWT", "tok")
    out = tmp_path / "dump"
    code = dump.main(["--base-url", "https://slurm.example.org:6820", "--user", "svc",
                      "--output-dir", str(out)])
    assert code == 0
    assert seen == {"base_url": "https://slurm.example.org:6820", "user": "svc",
                    "token": "tok"}
    names = sorted(p.name for p in out.iterdir())
    assert names == ["jobs.json", "manifest.json", "nodes.json", "openapi.json",
                     "partitions.json", "qos.json", "shares.json"]
    manifest = json.loads((out / "manifest.json").read_text())
    assert manifest["anonymised"] is True
    assert manifest["api_versions"]["slurm"] == "v0.0.41"
    assert "slurm.example.org" not in json.dumps(manifest) and "tok" not in manifest
    assert "jdoe" not in (out / "jobs.json").read_text()
    printed = capsys.readouterr().out
    assert "jobs.json" in printed and "bytes" in printed and "Self-check" in printed

    code = dump.main(["--base-url", "https://slurm.example.org:6820", "--no-anonymise",
                      "--output-dir", str(out)])
    assert code == 0 and "jdoe" in (out / "jobs.json").read_text()
    assert "NOT anonymised" in capsys.readouterr().out
