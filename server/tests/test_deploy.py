"""The files in server/deploy and what the documents say about them."""

from __future__ import annotations

import re
import tomllib
from pathlib import Path

SERVER = Path(__file__).parent.parent
DEPLOY = SERVER / "deploy"
DOCS = SERVER.parent / "docs"


def settings_of(unit: str) -> list[str]:
    """The non-comment lines of a unit file, continuation lines joined."""
    text = (DEPLOY / unit).read_text(encoding="utf-8").replace("\\\n", " ")
    return [line.strip() for line in text.splitlines() if line.strip() and line[0] != "#"]


def test_server_unit_shows_the_static_tokens_in_single_quotes():
    text = (DEPLOY / "slurm-monitor-server.service").read_text(encoding="utf-8")
    assert """#   SLURM_MONITOR_AUTH__STATIC__TOKENS='["..."]'""" in text
    assert "TOKENS=[" not in text
    readme = (SERVER / "README.md").read_text(encoding="utf-8")
    assert """SLURM_MONITOR_AUTH__STATIC__TOKENS='[""" in readme


def test_token_rotation_is_a_timer_and_a_oneshot_service_ordered_before_the_server():
    timer = settings_of("slurm-monitor-token.timer")
    assert "OnBootSec=30s" in timer and "OnUnitActiveSec=30min" in timer
    assert "Unit=slurm-monitor-token.service" in timer and "WantedBy=timers.target" in timer

    service = settings_of("slurm-monitor-token.service")
    assert "Type=oneshot" in service
    assert "Before=slurm-monitor-server.service" in service
    command = next(line for line in service if line.startswith("ExecStart="))
    assert "scontrol token username=" in command and "lifespan=7200" in command
    # Written beside the target and renamed; an empty answer leaves the old token.
    assert "slurm.jwt.new" in command and "test -s" in command
    assert command.rstrip("'").endswith("/run/slurm-monitor/slurm.jwt")
    # The lifespan outlasts several timer periods.
    assert 7200 >= 4 * 30 * 60

    server = settings_of("slurm-monitor-server.service")
    after = next(line for line in server if line.startswith("After="))
    wants = next(line for line in server if line.startswith("Wants="))
    assert "slurm-monitor-token.service" in after and "slurm-monitor-token.service" in wants
    # One unit owns /run/slurm-monitor: the one that writes into it.
    assert "RuntimeDirectory=slurm-monitor" in service
    assert not any(line.startswith("RuntimeDirectory") for line in server)

    example = tomllib.loads((DEPLOY / "config.example.toml").read_text(encoding="utf-8"))
    assert example["slurm"]["token_file"] == "/run/slurm-monitor/slurm.jwt"


def test_readme_describes_the_timer_and_the_container_uid():
    readme = (SERVER / "README.md").read_text(encoding="utf-8")
    assert "cron.d" not in readme and "*/30" not in readme
    for needed in (
        "slurm-monitor-token.timer", "slurm-monitor-token.service", "OnBootSec=30s",
        "OnUnitActiveSec=30min", "readable by the user the server runs as", "uid 10001",
    ):  # fmt: skip
        assert needed in readme, needed
    containerfile = (DEPLOY / "Containerfile").read_text(encoding="utf-8")
    assert "USER 10001:10001" in containerfile


def test_containerfile_installs_from_the_lock_file():
    text = (DEPLOY / "Containerfile").read_text(encoding="utf-8")
    assert re.search(r"^COPY pyproject\.toml uv\.lock ", text, re.MULTILINE)
    assert re.search(r"^RUN uv sync --frozen --no-dev", text, re.MULTILINE)
    assert "pip install" not in text
    assert (SERVER / "uv.lock").is_file()


def test_example_configuration_leaves_the_api_version_to_detection():
    text = (DEPLOY / "config.example.toml").read_text(encoding="utf-8")
    example = tomllib.loads(text)
    assert "api_version" not in example["slurm"] and "db_api_version" not in example["slurm"]
    assert "# api_version =" in text and "/openapi/v3" in text
    oidc = example["auth"]["oidc"]
    assert oidc["required_entitlements"] == [] and oidc["allow_any_authenticated"] is False
    assert oidc["verify_audience"] is True and oidc["accept_opaque_tokens"] is True


def test_readme_states_the_limits_of_the_oidc_checks():
    readme = " ".join((SERVER / "README.md").read_text(encoding="utf-8").split())
    for needed in (
        "Opaque tokens cannot be audience-checked",
        "Any signed-in user may ask for another user's view",
        "does not enforce Slurm's `PrivateData`",
        "`allow_any_authenticated = true`",
        "`verify_audience = false`; this weakens the check",
        "`accept_opaque_tokens = true`",
        "Leave `slurm.api_version` unset",
    ):
        assert needed in readme, needed


def test_deployment_checklist_covers_gpu_indices_node_names_and_version_detection():
    checklist = " ".join((DOCS / "deployment-checklist.md").read_text(encoding="utf-8").split())
    for needed in ("`IDX` numbering", "`NodeAddr`", "Slurm node name", "detects the newest version",
                   "slurm_api_version"):  # fmt: skip
        assert needed in checklist, needed


def test_contract_states_the_node_state_mapping_in_order():
    contract = " ".join((DOCS / "contract.md").read_text(encoding="utf-8").split())
    order = ["`INVALID_REG`, `UNKNOWN` → `down`", "`MAINTENANCE` (the sinfo spellings",
             "`COMPLETING` → `allocated`", "else `RESERVED` → `drained`", "else `idle`",
             "`FUTURE` are left out entirely"]  # fmt: skip
    positions = [contract.index(part) for part in order]
    assert positions == sorted(positions)
    assert "`POWERED_DOWN`, `UNKNOWN`" not in contract
