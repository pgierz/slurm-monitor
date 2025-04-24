# A SLURM Monitoring Dashboard
> Build with things we learned at PyConDE 2025  
>
> The HPC Team  
> Alfred Wegener Institute for Polar and Marine Research  
> Bremerhaven, Germany  

## Using [`pixi`](https://pixi.sh/) as a build tool.

This has all be done. Below are the steps followed:

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

## Using [`dlt`](https://dlthubl.com) to grab SLURM REST API Data:

Next, we want a way to be able to download data into a database from
a REST API. We can do that with [`dlt`](https://dlthub.com/docs/intro).

```console
$ pixi run dlt init rest_api duckdb
```

Next, we use the example to get stuff from GitHub.
