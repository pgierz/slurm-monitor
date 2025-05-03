from .base import run_slurm_pipeline


def local():
    """
    Entry point for local execution: runs pipeline directly (no SSH tunnel).
    Loads configuration from TOML or environment as needed.
    """
    # TODO: Replace with actual config loading logic
    config = {
        "rest": {"base_url": "http://localhost:8080"},
        "credentials": {"username": "localuser", "token": None},
        "resources": {},
    }
    api_params = config["rest"]
    username = config["credentials"]["username"]
    token = config["credentials"].get("token")
    resource_config = config.get("resources", {})
    base_url = api_params["base_url"]
    return run_slurm_pipeline(
        base_url=base_url,
        username=username,
        token=token,
        resource_config=resource_config,
    )
