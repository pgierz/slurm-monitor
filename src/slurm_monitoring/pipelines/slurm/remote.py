#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Remote interaction with SLURM REST API and SLURM CLI through SSH tunnels
using Paramiko and subprocess
"""
import subprocess
import time
from typing import Any, Dict, Optional

import dlt
import paramiko
import requests

from ...logging import logger
from .generated import slurm_source


class SSHTunnel:
    """
    Create an SSH tunnel using Paramiko to access a remote service.
    """

    def __init__(
        self,
        ssh_host: str,
        ssh_port: int = 22,
        ssh_username: str = None,
        ssh_password: Optional[str] = None,
        ssh_key_path: Optional[str] = None,
        remote_host: str = "localhost",
        remote_port: int = 8080,
        local_port: int = 8080,
    ):
        self.ssh_host = ssh_host
        self.ssh_port = ssh_port
        self.ssh_username = ssh_username
        self.ssh_password = ssh_password
        self.ssh_key_path = ssh_key_path
        self.remote_host = remote_host
        self.remote_port = remote_port
        self.local_port = local_port

        self.client = None
        self.transport = None
        self.server = None
        self.is_running = False
        self.thread = None
        self.process = None
        self.slurm_username = None
        self.slurm_jwt_token = None

    def start(self):
        """Start the SSH tunnel using the ssh command"""
        if self.is_running:
            return

        # Build the SSH command
        cmd = [
            "ssh",
            "-N",
            "-L",
            f"{self.local_port}:{self.remote_host}:{self.remote_port}",
        ]

        # Add identity file if provided
        if self.ssh_key_path:
            cmd.extend(["-i", self.ssh_key_path])

        # Add port if not default
        if self.ssh_port != 22:
            cmd.extend(["-p", str(self.ssh_port)])

        # Add username and host
        cmd.append(f"{self.ssh_username}@{self.ssh_host}")

        logger.info(f"Starting SSH tunnel with command: {' '.join(cmd)}")

        # Start the SSH tunnel process
        self.process = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )

        # Wait a moment for the tunnel to establish
        time.sleep(0.1)

        # Check if the process is still running
        if self.process.poll() is not None:
            stdout, stderr = self.process.communicate()
            raise RuntimeError(f"SSH tunnel failed to start: {stderr.decode('utf-8')}")

        self.is_running = True
        logger.success(
            f"SSH tunnel established: localhost:{self.local_port} -> {self.remote_host}:{self.remote_port}"
        )

    def stop(self):
        """Stop the SSH tunnel"""
        if not self.is_running:
            return

        if self.process:
            self.process.terminate()
            self.process.wait()

        self.is_running = False
        logger.info("SSH tunnel closed")

    def execute_command(self, command: str) -> str:
        """
        Execute a command on the remote server and return the output.

        Args:
            command: The command to execute

        Returns:
            The command output (stdout)
        """
        # Create a new SSH client for command execution
        client = paramiko.SSHClient()
        client.load_system_host_keys()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        # [FIXME] This can be a with statement...
        try:
            # Connect with either password or key
            if self.ssh_key_path:
                key = paramiko.RSAKey.from_private_key_file(self.ssh_key_path)
                client.connect(
                    self.ssh_host,
                    port=self.ssh_port,
                    username=self.ssh_username,
                    pkey=key,
                )
            else:
                client.connect(
                    self.ssh_host,
                    port=self.ssh_port,
                    username=self.ssh_username,
                    password=self.ssh_password,
                )

            # Execute the command
            stdin, stdout, stderr = client.exec_command(command)
            output = stdout.read().decode("utf-8").strip()
            error = stderr.read().decode("utf-8").strip()

            if error:
                logger.error(f"Warning: Command produced error output: {error}")

            return output
        finally:
            client.close()

    def generate_slurm_token(
        self,
        username: str = None,
        lifespan: int = 3600,
    ) -> str:
        """
        Generate a SLURM Java Web Token (JWT) using the scontrol command.

        Parameters
        ----------
        username : str, optional
            The username to generate the token for
        lifespan : str, optional
            The token lifespan in seconds (default: 1 hour)

        Returns
        -------
        Tuple[str, str]:
            var_name, token:  The generated SLURM API shell variable name and
            corresponding token
        """
        if username is None:
            username = self.ssh_username
        command = f"scontrol token username={username} lifespan={lifespan}"
        response = self.execute_command(command)
        var_name, token = response.split("=")

        if not token or "error" in token.lower():
            raise RuntimeError(f"Failed to generate SLURM token: {token}")
        logger.success("Token generated successfully!")

        self.slurm_username = username
        self.slurm_jwt_token = token
        return var_name, token

    def run_func(self, func, *args, **kwargs):
        """
        Run a function through the SSH tunnel, replacing the base_url
        parameter, username, and token.
        """
        tunnel_was_already_running = self.is_running
        if not self.is_running:
            self.start()

        # Override the base_url to use local tunnel endpoint
        kwargs["base_url"] = f"http://localhost:{self.local_port}"
        if self.slurm_username:
            kwargs["username"] = self.slurm_username
        if self.slurm_jwt_token:
            kwargs["token"] = self.slurm_jwt_token
        rval = func(*args, **kwargs)
        if not tunnel_was_already_running:
            self.stop()
        return rval


def ping_slurm_api(
    username: str,
    token: str,
    base_url: str,
    endpoint: str = "ping",
    **kwargs,
):
    """
    Ping the SLURM API to check if it is reachable

    Parameters
    ----------
    username : str
        The username to use for authentication
    token : str
        The token to use for authentication
    base_url : str
        The base URL to use for the request
    endpoint : str, optional
        The endpoint to ping (default: "ping")

    Returns
    -------
    requests.Response
        The response from the request
    """
    headers = {
        "X-SLURM-USER-NAME": username,
        "X-SLURM-USER-TOKEN": token,
    }
    url = f"{base_url}/slurm/v0.0.38/{endpoint}"
    response = requests.get(url, headers=headers)
    response.raise_for_status()
    # Check the response
    if response.status_code == 200:
        logger.success("Pinged SLURM API successfully!")
        logger.success(f"Response: {response.json()}")
    else:
        logger.error("Failed to ping SLURM API!")
        logger.error(f"Response: {response}")
    return response


def get_slurm_openapi_spec(
    username: str,
    token: str,
    base_url: str,
    **kwargs,
):
    headers = {
        "X-SLURM-USER-NAME": username,
        "X-SLURM-USER-TOKEN": token,
    }
    url = f"{base_url}/openapi.json"
    response = requests.get(url, headers=headers)
    response.raise_for_status()
    return response


def load_slurm_data(**config) -> Dict[str, Any]:
    """
    Load data from the SLURM REST API into a DuckDB database.

    Parameters
    ----------
    config : dict
        Dictionary containing all relevant config sections (rest,
        credentials, resources, etc.)
    Returns
    -------
    load_info : dict
        Information about the load operation
    """
    base_url = config.get("base_url")
    username = config.get("username")
    token = config.get("token")

    pipeline = dlt.pipeline(
        pipeline_name="slurm_pipeline",
        destination="duckdb",
        dataset_name="slurm_data",
    )
    load_info = pipeline.run(
        slurm_source(
            username=username,
            token=token,
            base_url=base_url,
        )
    )
    return load_info


def get_ssh_config():
    # [FIXME] It would be nice if these configuration values came from THE
    #         CONFIG FILE OUTSIDE (e.g. config.toml), but we have to live
    #         with it for now...
    return {
        "ssh_username": "pgierz",
        "ssh_host": "albedo0.dmawi.de",
        "remote_host": "slurm",
        "remote_port": "6820",
    }


def run():
    logger.info("Starting **REMOTE** SLURM REST API Ingestion Pipeline...")
    ssh_config = get_ssh_config()
    ssh_tunnel = SSHTunnel(**ssh_config)
    ssh_tunnel.generate_slurm_token()
    ssh_tunnel.run_func(ping_slurm_api)

    # Create the OpenAPI spec for the SLURM API
    openapi_response = ssh_tunnel.run_func(get_slurm_openapi_spec)
    with open("slurm_openapi.json", "w") as f:
        f.write(openapi_response.text)

    # [NOTE] Groovy. We got pretty far by now. I can now ping the SLURM API
    #        through the SSH Tunnel. Now, we hook up the pipeline...
    pipeline_result = ssh_tunnel.run_func(load_slurm_data)
    logger.success("Pipeline run complete!")
    logger.success(f"Load info: {pipeline_result}")


if __name__ == "__main__":
    run()
