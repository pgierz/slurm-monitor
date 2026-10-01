"""Configuration: one TOML file plus environment overrides.

The file path comes from ``SLURM_MONITOR_CONFIG``. Every setting can be
overridden by an environment variable named ``SLURM_MONITOR_<SECTION>__<KEY>``
(for example ``SLURM_MONITOR_SLURM__TOKEN``); secrets are meant to be supplied
that way or through files, never written into the code.
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator
from pydantic_settings import (
    BaseSettings,
    PydanticBaseSettingsSource,
    SettingsConfigDict,
    TomlConfigSettingsSource,
)

CONFIG_ENV_VARIABLE = "SLURM_MONITOR_CONFIG"


class ListenSettings(BaseModel):
    host: str = "127.0.0.1"
    port: int = 8080


class SlurmSettings(BaseModel):
    base_url: str = "http://localhost:6820"
    api_version: str = "v0.0.40"
    # Version of the slurmdb plugin; the same as api_version when not given.
    db_api_version: str | None = None
    user_name: str = ""
    # Exactly one of the three token settings is normally used.
    token: str | None = None
    token_file: Path | None = None
    token_command: str | None = None
    # How long a token obtained from token_command is reused.
    token_command_ttl_seconds: int = 1800
    timeout_seconds: float = 30.0
    # Path to a CA bundle for slurmrestd behind TLS; None uses the system store.
    ca_file: Path | None = None

    @property
    def effective_db_api_version(self) -> str:
        return self.db_api_version or self.api_version


class PollSettings(BaseModel):
    interval_seconds: float = Field(default=60.0, gt=0)
    # The contract caps history at 72 points of 5 minutes (6 hours); a shorter
    # window may be set here.
    history_window_seconds: int = Field(default=6 * 3600, gt=0)


def _checked_pattern(value: str) -> str:
    try:
        re.compile(value)
    except re.error as error:
        raise ValueError(f"not a regular expression: {error}") from error
    return value


class ExtraRunnerKind(BaseModel):
    key: str
    label: str
    pattern: str

    @field_validator("pattern")
    @classmethod
    def _pattern_compiles(cls, value: str) -> str:
        return _checked_pattern(value)


class RunnerSettings(BaseModel):
    ci_pattern: str = r"^ci-\d+"
    dask_pattern: str = r"^dask-gateway"
    dask_scheduler_pattern: str = r"scheduler"
    # Job field whose value names the Dask cluster a job belongs to.
    dask_cluster_field: str = "comment"
    jupyterhub_pattern: str = r"^(spawner-)?jupyterhub"
    extra: list[ExtraRunnerKind] = Field(default_factory=list)

    @field_validator("ci_pattern", "dask_pattern", "dask_scheduler_pattern", "jupyterhub_pattern")
    @classmethod
    def _pattern_compiles(cls, value: str) -> str:
        return _checked_pattern(value)


class GpuMetricsSettings(BaseModel):
    source: Literal["none", "prometheus", "collector"] = "none"
    timeout_seconds: float = 5.0
    # prometheus
    prometheus_url: str | None = None
    prometheus_node_label: str = "Hostname"
    prometheus_gpu_label: str = "gpu"
    # Extra label matchers put into every query, e.g. 'cluster="example"'.
    prometheus_extra_matchers: str = ""
    # collector
    collector_port: int = 9455
    collector_scheme: str = "http"

    @model_validator(mode="after")
    def _prometheus_needs_url(self) -> GpuMetricsSettings:
        if self.source == "prometheus" and not self.prometheus_url:
            raise ValueError("gpu.metrics.prometheus_url is required for source 'prometheus'")
        return self


class GpuSettings(BaseModel):
    # GRES name that denotes GPUs.
    gres_name: str = "gpu"
    # Display labels by lower-case GRES type; unknown types are upper-cased.
    labels: dict[str, str] = Field(default_factory=dict)
    metrics: GpuMetricsSettings = Field(default_factory=GpuMetricsSettings)


class StaticTokenSettings(BaseModel):
    enabled: bool = False
    tokens: list[str] = Field(default_factory=list)


class OidcSettings(BaseModel):
    enabled: bool = False
    issuer: str = ""
    client_id: str = ""
    scopes: list[str] = Field(
        default_factory=lambda: [
            "openid",
            "profile",
            "email",
            "eduperson_entitlement",
            "offline_access",
        ]
    )
    # Checked against the token's "aud" claim when set.
    audience: str | None = None
    username_claim: str = "preferred_username"
    # When not empty, the identity must carry at least one of these values in
    # its eduperson_entitlement or groups claim.
    required_entitlements: list[str] = Field(default_factory=list)
    # Explicit mapping to Slurm user names; keys are the subject or the value
    # of username_claim.
    username_map: dict[str, str] = Field(default_factory=dict)
    jwks_cache_seconds: int = 3600
    userinfo_cache_seconds: int = 300
    timeout_seconds: float = 10.0

    @model_validator(mode="after")
    def _enabled_needs_issuer(self) -> OidcSettings:
        if self.enabled and (not self.issuer or not self.client_id):
            raise ValueError("auth.oidc.issuer and auth.oidc.client_id are required")
        return self


class AuthSettings(BaseModel):
    static: StaticTokenSettings = Field(default_factory=StaticTokenSettings)
    oidc: OidcSettings = Field(default_factory=OidcSettings)


class PrometheusExportSettings(BaseModel):
    enabled: bool = False


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="SLURM_MONITOR_",
        env_nested_delimiter="__",
        extra="ignore",
    )

    cluster: str = "cluster"
    listen: ListenSettings = Field(default_factory=ListenSettings)
    slurm: SlurmSettings = Field(default_factory=SlurmSettings)
    poll: PollSettings = Field(default_factory=PollSettings)
    runners: RunnerSettings = Field(default_factory=RunnerSettings)
    gpu: GpuSettings = Field(default_factory=GpuSettings)
    auth: AuthSettings = Field(default_factory=AuthSettings)
    metrics: PrometheusExportSettings = Field(default_factory=PrometheusExportSettings)

    @classmethod
    def settings_customise_sources(
        cls,
        settings_cls: type[BaseSettings],
        init_settings: PydanticBaseSettingsSource,
        env_settings: PydanticBaseSettingsSource,
        dotenv_settings: PydanticBaseSettingsSource,
        file_secret_settings: PydanticBaseSettingsSource,
    ) -> tuple[PydanticBaseSettingsSource, ...]:
        sources: list[PydanticBaseSettingsSource] = [init_settings, env_settings]
        config_path = os.environ.get(CONFIG_ENV_VARIABLE)
        if config_path:
            if not Path(config_path).is_file():
                raise FileNotFoundError(f"{CONFIG_ENV_VARIABLE} points to a missing file")
            sources.append(TomlConfigSettingsSource(settings_cls, toml_file=config_path))
        return tuple(sources)


def load_settings() -> Settings:
    """Read the TOML file named by SLURM_MONITOR_CONFIG and the environment."""
    return Settings()
