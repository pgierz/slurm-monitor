# A SLURM Monitoring Dashboard
> Build with things we learned at PyConDE 2025
>
> The HPC Team
> Alfred Wegener Institute for Polar and Marine Research
> Bremerhaven, Germany

[![Documentation Status](https://readthedocs.org/projects/slurm-monitor/badge/?version=latest)](https://slurm-monitor.readthedocs.io/en/latest/?badge=latest)

## Install
Not sure how the install for this works out yet. Probably via `pip`?
```
$ pip install git+https://github.com/pgierz/slurm-monitor.git
```

## Usage
If you have a "real" install, you should be able to do:
```console
$ slurm-monitor
```

If you have a source-install and are using `pixi`:
```console
$ pixi run slurm-monitor
```

Examine the database:
```console
$ pixi run slurm-dbshow
```

## Learning from PyConDE 2025

### Using [`pixi`](https://pixi.sh/) as a build tool.

This has all been done. Below are the steps followed:

1. Set up a new project:
```console
$ pixi init --format pyproject
```

2. Add a package (e.g. [`dlt`](https://dlthub.com/docs/intro))
```console
$ pixi add dlt        # For data ingestion
$ pixi add duckdb     # For data storage
$ pixi add streamlit  # For plotting/dashboarding
```

### Using [`dlt`](https://dlthub.com) to grab SLURM REST API Data:

Next, we want a way to be able to download data into a database from
a REST API. We can do that with [`dlt`](https://dlthub.com/docs/intro).

```console
$ pixi run dlt init rest_api duckdb
```

Next, we use the example to get stuff from GitHub.
