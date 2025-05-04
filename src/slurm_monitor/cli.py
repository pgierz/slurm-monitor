import importlib
import sys

import click


@click.group()
def cli():
    """slurm-monitoring CLI"""
    pass


@cli.command()
@click.argument("module_spec")
@click.argument("action")
def pipeline(module_spec, action):
    """Run a pipeline given a module spec and action."""
    try:
        module = importlib.import_module(f"slurm_monitoring.pipelines.{module_spec}")
    except ModuleNotFoundError as e:
        click.echo(
            f"Module 'slurm_monitoring.pipelines.{module_spec}' not found.", err=True
        )
        click.echo(e)
        sys.exit(1)
    if hasattr(module, action):
        func = getattr(module, action)
        (
            func()
            if callable(func)
            else click.echo(f"Attribute '{action}' is not callable.", err=True)
        )
    else:
        click.echo(f"Action '{action}' not found in module '{module_spec}'.", err=True)
        sys.exit(2)


if __name__ == "__main__":
    cli()
