# Metrics reference

All metrics carry a `cluster` label (default `albedo`). Set
`SLURM_MONITOR_SLURM_CLUSTER` if you operate more than one.

## Allowed labels

| Label | Source | Cardinality |
|---|---|---|
| `cluster` | config | 1 today, ready for ≥2 |
| `partition` | slurmrestd | small |
| `qos` | slurmrestd | small |
| `account` | slurmrestd | tens |
| `user` | slurmrestd | hundreds (active) |
| `state` | slurmrestd | small enum |
| `reason` | slurmrestd (pending jobs) | bounded enum |
| `node` | slurmrestd (node metrics only) | ~240 on Albedo |
| `gpu_type` | parsed from `gres` | small (a100, a40, none) |
| `reservation`, `reason`, `users`, `accounts` | reservations only | tiny |

## Forbidden labels

We will **not** add the following — they create metric explosion or leak
identifiers we do not need:

* `jobid` — billions over time
* `executable` — unbounded text
* `hostname` (FQDN) — `node` is the canonical short form
* `pid`, `step_id`

## Node metrics

| Metric | Type | Labels | Notes |
|---|---|---|---|
| `slurm_node_cpus_total` | gauge | cluster, node, partition, gpu_type | Configured CPUs. |
| `slurm_node_cpus_alloc` | gauge | cluster, node, partition, gpu_type | Allocated CPUs. |
| `slurm_node_cpu_load` | gauge | cluster, node, partition, gpu_type | 1-min load (cpu_load / 100). |
| `slurm_node_real_memory_mb` | gauge | as above | Configured memory in MB. |
| `slurm_node_alloc_memory_mb` | gauge | as above | Allocated memory in MB. |
| `slurm_node_free_memory_mb` | gauge | as above | Free memory reported by the node in MB. |
| `slurm_node_gpus_total` | gauge | cluster, node, partition, gpu_type | Configured GPUs by model. |
| `slurm_node_gpus_alloc` | gauge | cluster, node, partition, gpu_type | Allocated GPUs by model. |
| `slurm_node_state` | gauge (1-hot) | cluster, node, partition, gpu_type, state | Multiple state tokens emit multiple series, all =1. |

Aggregations:

| Metric | Labels | Notes |
|---|---|---|
| `slurm_nodes_state_count` | cluster, partition, state | Count of nodes per partition/state. |
| `slurm_partition_gpus_total` | cluster, partition, gpu_type | Sum of node GPUs per partition. |
| `slurm_partition_gpus_alloc` | cluster, partition, gpu_type | Sum of allocated GPUs per partition. |

## Job metrics (aggregated, not per-jobid)

| Metric | Labels |
|---|---|
| `slurm_jobs` | cluster, partition, qos, account, user, state |
| `slurm_jobs_cpus` | cluster, partition, qos, account, user, state |
| `slurm_jobs_gpus` | cluster, partition, qos, account, user, state |
| `slurm_jobs_nodes` | cluster, partition, qos, account, user, state |
| `slurm_jobs_pending_by_reason` | cluster, partition, qos, account, user, reason |
| `slurm_jobs_wait_seconds_max` | cluster, partition, qos |
| `slurm_jobs_wait_seconds_sum` | cluster, partition, qos |

## Partition metrics

| Metric | Labels |
|---|---|
| `slurm_partition_cpus_total` | cluster, partition |
| `slurm_partition_nodes_total` | cluster, partition |
| `slurm_partition_max_time_minutes` | cluster, partition |
| `slurm_partition_default_time_minutes` | cluster, partition |
| `slurm_partition_state` | cluster, partition, state |

## Scheduler diagnostics

| Metric | Labels | Notes |
|---|---|---|
| `slurm_scheduler_cycle_last_microseconds` | cluster | Most recent main-cycle duration. |
| `slurm_scheduler_cycle_max_microseconds` | cluster | Max since slurmctld started. |
| `slurm_scheduler_queue_length` | cluster | RPC queue length. |
| `slurm_backfill_cycle_last_microseconds` | cluster | Most recent backfill-cycle duration. |
| `slurm_backfill_last_depth` | cluster | Jobs evaluated in last backfill. |
| `slurm_jobs_started_total` | cluster | Counter (deltas reconstructed from slurmctld counter). |
| `slurm_jobs_completed_total` | cluster | Counter. |

## Reservations

| Metric | Labels |
|---|---|
| `slurm_reservation_start_time_seconds` | cluster, reservation, partition, users, accounts |
| `slurm_reservation_end_time_seconds` | cluster, reservation, partition, users, accounts |
| `slurm_reservation_node_count` | cluster, reservation, partition, users, accounts |
| `slurm_reservation_active` | cluster, reservation, partition, users, accounts |

## Exporter health

| Metric | Labels | Notes |
|---|---|---|
| `slurm_monitor_up` | cluster, collector | 1 once a collector has succeeded at least once. |
| `slurm_monitor_collector_last_success_timestamp_seconds` | cluster, collector | Used by `SlurmCollectorStale` alert. |
| `slurm_monitor_collector_duration_seconds` | cluster, collector | Last successful collection duration. |
| `slurm_monitor_collector_errors_total` | cluster, collector, reason | Counter. |
| `slurm_monitor_slurm_api_version_info` | cluster, version | 1; the `version` label is the value. |
| `slurm_monitor_build_info` | (Info) | Version + cluster + slurmrestd URL. |
