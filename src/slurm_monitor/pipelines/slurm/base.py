"""
Defines a basic DLT resource for the SLURM REST API.

See Also
--------
* Online version of REST API: https://slurm.schedmd.com/rest_api.html
"""

from typing import Any

import dlt
from dlt.sources.rest_api import RESTAPIConfig, rest_api_resources
from loguru import logger


@dlt.source(name="slurm")
def slurm_source(
    base_url: str = dlt.config.value,
    username: str = dlt.secrets.value,
    token: str = dlt.secrets.value,
) -> Any:
    """
    A DLT source for the SLURM REST API.
    Parameters
    ----------
        base_url: The base URL for the SLURM REST API (e.g., "http://slurm/v0.0.38")
        username: Optional username for authentication
        token: Optional token for authentication
    Yields
    ------
        A generator of resources from the SLURM REST API
    """

    # Create a REST API configuration for the SLURM API
    config: RESTAPIConfig = {
        "client": {
            "base_url": base_url,
            "headers": {
                "X-SLURM-USER-NAME": username,
                "X-SLURM-USER-TOKEN": token,
            },
        },
        # Default configuration for all resources
        "resource_defaults": {
            "write_disposition": "merge",
        },
        "resources": [],
    }

    # Define all available resources
    all_resources = {
        "nodes": {
            "name": "nodes",
            "endpoint": {
                "path": "nodes",
            },
            "primary_key": "name",  # Assuming each node has a unique name
        },
        "partitions": {
            "name": "partitions",
            "endpoint": {
                "path": "partitions",
            },
            "primary_key": "name",  # Each partition has a unique name
        },
        "jobs": {
            "name": "jobs",
            "endpoint": {
                "path": "jobs",
                "params": {
                    # You can add filters here based on SLURM REST API documentation
                },
            },
            "primary_key": "job_id",  # Each job has a unique ID
        },
        "job_details": {
            "name": "job_details",
            "endpoint": {
                "path": "job/{job_id}",
                "params": {
                    "job_id": {
                        "type": "resolve",
                        "resource": "jobs",
                        "field": "job_id",
                    },
                },
            },
            "primary_key": "job_id",
            "include_from_parent": ["job_id"],
        },
        "reservations": {
            "name": "reservations",
            "endpoint": {
                "path": "reservations",
            },
            "primary_key": "name",
        },
        "diag": {
            "name": "diag",
            "endpoint": {
                "path": "diag",
            },
        },
    }
    config["resources"] = list(all_resources.values())

    try:
        resources = rest_api_resources(config)
        logger.info("Fetching resources from SLURM API...")
        yield from resources

    except Exception as e:
        logger.error(f"Error accessing SLURM API: {str(e)}")
        raise e
