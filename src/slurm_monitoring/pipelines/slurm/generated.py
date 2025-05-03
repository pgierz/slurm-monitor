import json
import pdb
from typing import List

import dlt
import requests
from dlt.extract.source import DltResource
from dlt.sources.helpers.rest_client.auth import AuthConfigBase
from dlt.sources.rest_api import RESTAPIConfig, rest_api_resources

from ...logging import logger


class SlurmAuthConfig(AuthConfigBase):
    """Custom authentication class for the Slurm REST API"""

    def __init__(self, username: str, token: str, **kwargs):
        super().__init__(**kwargs)
        self.username = username
        self.token = token

    def __call__(self, request):
        # Add custom authentication headers
        request.headers["X-SLURM-USER-NAME"] = self.username
        request.headers["X-SLURM-USER-TOKEN"] = self.token
        return request


def manual_get(
    resource: dict,
    username: str,
    token: str,
    base_url: str,
) -> requests.Response:
    """
    Runs a GET request at the resource

    Parameters
    ----------
    resource: dict
        The resource to get, as specified for DLT.
    username: str
        The username to use for authentication
    token: str
        The token to use for authentication
    base_url: str
        The base URL to use for the request

    Returns
    -------
    requests.Response
        The response from the request
    """
    endpoint = resource["endpoint"]
    path = endpoint["path"]
    headers = {
        "X-SLURM-USER-NAME": username,
        "X-SLURM-USER-TOKEN": token,
    }
    url = f"{base_url}/{path}"
    response = requests.get(url, headers=headers)
    # Check the response
    if response.status_code == 200:
        logger.success(f"Pinged SLURM API {path} successfully!")
        logger.success(f"Response: {json.dumps(response.json(), indent=2)}")
    else:
        logger.error(f"Failed to get {path} from SLURM API!")
        logger.error(f"Response: {json.dumps(response.json(), indent=2)}")
    return response


@dlt.source(
    name="slurm_source",
    max_table_nesting=2,
)
def slurm_source(
    username: str = dlt.secrets.value,
    token: str = dlt.secrets.value,
    base_url: str = dlt.config.value,
) -> List[DltResource]:

    auth = SlurmAuthConfig(
        username=username,
        token=token,
    )

    # source configuration
    source_config: RESTAPIConfig = {
        "client": {
            "base_url": base_url,
            "auth": auth,
        },
        "resources": [
            # #################################################################
            # [NOTE]: This one doesn't work
            # {
            #     "name": "slurmdb_v0_0_38_diag",
            #     "table_name": "dbv0_0_38_diag",
            #     "endpoint": {
            #         "data_selector": "$",
            #         "path": "/slurmdb/v0.0.38/diag",
            #         "paginator": "auto",
            #     },
            # },
            # #################################################################
            # # This endpoint may return multiple job entries since job_id is not a unique key - only the tuple (cluster, job_id, start_time) is unique. If the requested job_id is a component of a heterogeneous job all components are returned.
            # {
            #     "name": "slurmdb_v0_0_38_get_job",
            #     "table_name": "dbv0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurmdb/v0.0.38/job/{job_id}",
            #         "paginator": "auto",
            #         "params": {
            #             "job_id": {
            #                 "type": "resolve",
            #                 "resource": "slurmdb_v0_0_38_get_jobs",
            #                 "field": "job_id",
            #             },
            #         },
            #     },
            # },
            # #################################################################
            # [NOTE] This one doesn't work: Protocol authentication error
            # {
            #     "name": "slurmdb_v0_0_38_get_config",
            #     "table_name": "dbv0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurmdb/v0.0.38/config",
            #         "paginator": "auto",
            #     },
            # },
            # #################################################################
            # [NOTE] This one doesn't work, but I don't think we have that
            #        plugin active (needs "accounting_storage"??)
            # {
            #     "name": "slurmdb_v0_0_38_get_tres",
            #     "table_name": "dbv0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurmdb/v0.0.38/tres",
            #         "paginator": "auto",
            #     },
            # },
            # #################################################################
            # {
            #     "name": "slurmdb_v0_0_38_get_single_qos",
            #     "table_name": "dbv0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurmdb/v0.0.38/qos/{qos_name}",
            #         "params": {
            #             "qos_name": {
            #                 "type": "resolve",
            #                 "resource": "slurmdb_v0_0_38_get_qos",
            #                 "field": "qos_name",
            #             },
            #         },
            #         "paginator": "auto",
            #     },
            # },
            # {
            #     "name": "slurmdb_v0_0_38_get_qos",
            #     "table_name": "dbv0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurmdb/v0.0.38/qos",
            #         "params": {
            #             # the parameters below can optionally be configured
            #             # "with_deleted": "OPTIONAL_CONFIG",
            #         },
            #         "paginator": "auto",
            #     },
            # },
            # {
            #     "name": "slurmdb_v0_0_38_get_associations",
            #     "table_name": "dbv0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurmdb/v0.0.38/associations",
            #         "params": {
            #             # the parameters below can optionally be configured
            #             # "cluster": "OPTIONAL_CONFIG",
            #             # "account": "OPTIONAL_CONFIG",
            #             # "user": "OPTIONAL_CONFIG",
            #             # "partition": "OPTIONAL_CONFIG",
            #         },
            #         "paginator": "auto",
            #     },
            # },
            # {
            #     "name": "slurmdb_v0_0_38_get_association",
            #     "table_name": "dbv0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurmdb/v0.0.38/association",
            #         "params": {
            #             # the parameters below can optionally be configured
            #             # "cluster": "OPTIONAL_CONFIG",
            #             # "account": "OPTIONAL_CONFIG",
            #             # "user": "OPTIONAL_CONFIG",
            #             # "partition": "OPTIONAL_CONFIG",
            #         },
            #         "paginator": "auto",
            #     },
            # },
            # {
            #     "name": "slurmdb_v0_0_38_get_user",
            #     "table_name": "dbv0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurmdb/v0.0.38/user/{user_name}",
            #         "params": {
            #             "user_name": {
            #                 "type": "resolve",
            #                 "resource": "slurmdb_v0_0_38_get_users",
            #                 "field": "user_name",
            #             },
            #         },
            #         "paginator": "auto",
            #     },
            # },
            # {
            #     "name": "slurmdb_v0_0_38_get_users",
            #     "table_name": "dbv0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurmdb/v0.0.38/users",
            #         "params": {
            #             # the parameters below can optionally be configured
            #             # "with_deleted": "OPTIONAL_CONFIG",
            #         },
            #         "paginator": "auto",
            #     },
            # },
            # {
            #     "name": "slurmdb_v0_0_38_get_wckey",
            #     "table_name": "dbv0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurmdb/v0.0.38/wckey/{wckey}",
            #         "paginator": "auto",
            #         "params": {
            #             "wckey": {
            #                 "type": "resolve",
            #                 "resource": "slurmdb_v0_0_38_get_wckeys",
            #                 "field": "wckey",
            #             },
            #         },
            #     },
            # },
            # {
            #     "name": "slurmdb_v0_0_38_get_wckeys",
            #     "table_name": "dbv0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurmdb/v0.0.38/wckeys",
            #         "paginator": "auto",
            #     },
            # },
            # {
            #     "name": "slurmdb_v0_0_38_get_account",
            #     "table_name": "dbv0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurmdb/v0.0.38/account/{account_name}",
            #         "params": {
            #             "account_name": {
            #                 "type": "resolve",
            #                 "resource": "slurmdb_v0_0_38_get_accounts",
            #                 "field": "account_name",
            #             }
            #         },
            #         "paginator": "auto",
            #     },
            # },
            # {
            #     "name": "slurmdb_v0_0_38_get_accounts",
            #     "table_name": "dbv0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurmdb/v0.0.38/accounts",
            #         "params": {
            #             # the parameters below can optionally be configured
            #             # "with_deleted": "OPTIONAL_CONFIG",
            #         },
            #         "paginator": "auto",
            #     },
            # },
            # {
            #     "name": "slurmdb_v0_0_38_get_jobs",
            #     "table_name": "dbv0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurmdb/v0.0.38/jobs",
            #         "params": {
            #             # the parameters below can optionally be configured
            #             # "submit_time": "OPTIONAL_CONFIG",
            #             # "start_time": "OPTIONAL_CONFIG",
            #             # "end_time": "OPTIONAL_CONFIG",
            #             # "account": "OPTIONAL_CONFIG",
            #             # "association": "OPTIONAL_CONFIG",
            #             # "cluster": "OPTIONAL_CONFIG",
            #             # "constraints": "OPTIONAL_CONFIG",
            #             # "cpus_max": "OPTIONAL_CONFIG",
            #             # "cpus_min": "OPTIONAL_CONFIG",
            #             # "skip_steps": "OPTIONAL_CONFIG",
            #             # "disable_wait_for_result": "OPTIONAL_CONFIG",
            #             # "exit_code": "OPTIONAL_CONFIG",
            #             # "format": "OPTIONAL_CONFIG",
            #             # "group": "OPTIONAL_CONFIG",
            #             # "job_name": "OPTIONAL_CONFIG",
            #             # "nodes_max": "OPTIONAL_CONFIG",
            #             # "nodes_min": "OPTIONAL_CONFIG",
            #             # "partition": "OPTIONAL_CONFIG",
            #             # "qos": "OPTIONAL_CONFIG",
            #             # "reason": "OPTIONAL_CONFIG",
            #             # "reservation": "OPTIONAL_CONFIG",
            #             # "state": "OPTIONAL_CONFIG",
            #             # "step": "OPTIONAL_CONFIG",
            #             # "node": "OPTIONAL_CONFIG",
            #             # "wckey": "OPTIONAL_CONFIG",
            #         },
            #         "paginator": "auto",
            #     },
            # },
            # {
            #     "name": "slurmdb_v0_0_38_get_cluster",
            #     "table_name": "v0",
            #     "endpoint": {
            #         "data_selector": "flags",
            #         "path": "/slurmdb/v0.0.38/cluster/{cluster_name}",
            #         "paginator": "auto",
            #         "params": {
            #             "cluster_name": {
            #                 "type": "resolve",
            #                 "resource": "slurmdb_v0_0_38_get_clusters",
            #                 "field": "cluster_name",
            #             },
            #         },
            #     },
            # },
            # {
            #     "name": "slurmdb_v0_0_38_get_clusters",
            #     "table_name": "v0",
            #     "endpoint": {
            #         "data_selector": "flags",
            #         "path": "/slurmdb/v0.0.38/clusters",
            #         "paginator": "auto",
            #     },
            # },
            {
                "name": "slurm_v0_0_38_diag",
                "table_name": "v0_0_38_diag",
                "endpoint": {
                    "data_selector": "statistics",
                    "path": "/slurm/v0.0.38/diag",
                    "paginator": "auto",
                },
            },
            {
                "name": "slurm_v0_0_38_slurmctld_get_licenses",
                "table_name": "v0_0_38_error",
                "endpoint": {
                    "data_selector": "licenses",
                    "path": "/slurm/v0.0.38/licenses",
                    "paginator": "auto",
                },
            },
            {
                "name": "slurm_v0_0_38_ping",
                "table_name": "v0_0_38_ping",
                "endpoint": {
                    "data_selector": "pings",
                    "path": "/slurm/v0.0.38/ping",
                    "paginator": "single_page",
                },
            },
            {
                "name": "slurm_v0_0_38_get_jobs",
                "table_name": "v0_0_38_jobs_overview",
                "endpoint": {
                    "data_selector": "jobs",
                    "path": "/slurm/v0.0.38/jobs",
                    "params": {
                        # the parameters below can optionally be configured
                        # "update_time": "OPTIONAL_CONFIG",
                    },
                    "paginator": "single_page",
                },
            },
            {
                "name": "slurm_v0_0_38_get_job",
                "table_name": "v0_0_38_jobs",
                "endpoint": {
                    "data_selector": "jobs",
                    "path": "/slurm/v0.0.38/job/{job_id}",
                    "paginator": "single_page",
                    "params": {
                        "job_id": {
                            "type": "resolve",
                            "resource": "slurm_v0_0_38_get_jobs",
                            "field": "job_id",
                        }
                    },
                },
            },
            {
                "name": "slurm_v0_0_38_get_nodes",
                "table_name": "v0_0_38_nodes_overview",
                "endpoint": {
                    "data_selector": "nodes",
                    "path": "/slurm/v0.0.38/nodes",
                    "params": {
                        # the parameters below can optionally be configured
                        # "update_time": "OPTIONAL_CONFIG",
                    },
                    "paginator": "auto",
                },
            },
            {
                "name": "slurm_v0_0_38_get_node",
                "table_name": "v0_0_38_nodes",
                "endpoint": {
                    "data_selector": "$",
                    "path": "/slurm/v0.0.38/node/{name}",
                    "paginator": "single_page",
                    "params": {
                        "name": {
                            "type": "resolve",
                            "resource": "slurm_v0_0_38_get_nodes",
                            "field": "name",
                        },
                    },
                },
            },
            # {
            #     "name": "slurm_v0_0_38_get_partitions",
            #     "table_name": "v0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurm/v0.0.38/partitions",
            #         "params": {
            #             # the parameters below can optionally be configured
            #             # "update_time": "OPTIONAL_CONFIG",
            #         },
            #         "paginator": "auto",
            #     },
            # },
            # {
            #     "name": "slurm_v0_0_38_get_partition",
            #     "table_name": "v0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurm/v0.0.38/partition/{partition_name}",
            #         "params": {
            #             "partition_name": {
            #                 "type": "resolve",
            #                 "resource": "slurm_v0_0_38_get_partitions",
            #                 "field": "partition_name",
            #             },
            #         },
            #         "paginator": "auto",
            #     },
            # },
            # {
            #     "name": "slurm_v0_0_38_get_reservations",
            #     "table_name": "v0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurm/v0.0.38/reservations",
            #         "params": {
            #             # the parameters below can optionally be configured
            #             # "update_time": "OPTIONAL_CONFIG",
            #         },
            #         "paginator": "auto",
            #     },
            # },
            # {
            #     "name": "slurm_v0_0_38_get_reservation",
            #     "table_name": "v0_0_38_error",
            #     "endpoint": {
            #         "data_selector": "errors",
            #         "path": "/slurm/v0.0.38/reservation/{reservation_name}",
            #         "params": {
            #             "reservation_name": {
            #                 "type": "resolve",
            #                 "resource": "slurm_v0_0_38_get_reservations",
            #                 "field": "reservation_name",
            #             },
            #         },
            #         "paginator": "auto",
            #     },
            # },
        ],
    }

    # [FIXME] This belongs somewhere else...
    # Interactively call the requests "raw" first, to
    # see their responses...
    for resource in source_config["resources"]:
        manual_get(
            resource,
            username,
            token,
            base_url,
        )

    try:
        resources = rest_api_resources(source_config)
        # for resource in resources:
        #     logger.info(f"Resource: {resource.name}")
        #     for value in resource:
        #         logger.info(f"Value: {value}")
        # breakpoint()
        yield from resources
    except requests.exceptions.HTTPError as e:
        logger.error(e)
        pdb.post_mortem()
