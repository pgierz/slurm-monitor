# A SLURM Monitoring Dashboard
> Build with things we learned at PyConDE 2025  
>
> The HPC Team  
> Alfred Wegener Institute for Polar and Marine Research  
> Bremerhaven, Germany  

## Using [`pixi`](https://pixi.sh/) as a build tool.

Set up a new project:
```console
$ pixi init --format pyproject
```
Add a package (e.g. [`dlt`](https://dlthub.com/docs/intro))
```console
$ pixi add dlt
```

## Using [`dlt`](https://dlthubl.com) to grab SLURM REST API Data:
```console
$ pixi run dlt init rest_api duckdb
```
