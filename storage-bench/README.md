# storage-bench

A storage benchmark that measures one or more mounted filesystems with `fio`
and then with a real PostgreSQL workload, and writes a single self-contained
HTML report with time-series graphs.

Everything is configured through environment variables. The only arguments are
the paths to benchmark.

- [Quick start](#quick-start)
- [Arguments](#arguments)
- [Environment variables](#environment-variables)
  - [Output](#output)
  - [Run structure](#run-structure)
  - [fio](#fio)
  - [pgbench](#pgbench)
  - [Report](#report)
- [Justfile targets](#justfile-targets)
- [Justfile variables](#justfile-variables)
- [Output layout](#output-layout)
- [How long a run takes](#how-long-a-run-takes)

## Quick start

```sh
# on the machine being measured, using the published image
just bench /tank/backup

# two paths, head to head
just bench /tank/backup /mnt/ceph

# quicker: one pass, no postgres
REPEATS=1 PGBENCH=0 just bench /tank/backup

# build the image from this checkout first (needs Nix), then benchmark
just run /tank/backup

# without the container at all
nix-shell --run './storage-bench.sh /tank/backup'
```

Reports land in `bench-results/`, one timestamped directory per run.

## Arguments

```
storage-bench.sh <mount1> [<mount2> ...]
```

Every argument is a directory to benchmark. There are no flags — everything
else is an environment variable.

Each path must be a directory and must be writable by the user running the
benchmark. Paths that are not are skipped with a message rather than failing
the run; if none are usable the run stops.

Under `just bench` / `just run` each host path is bind-mounted into the
container at `/data/<basename>`, so two paths whose basenames collide
(`/tank/backup` and `/mnt/backup`) are refused rather than silently mounted
over each other.

## Environment variables

Defaults below are what the script uses, and are the same in
`storage-bench.sh` and `storage-bench.nu`.

### Output

| Variable | Default | Meaning |
| --- | --- | --- |
| `OUTBASE` | `/tmp` | Directory the run directory is created in. Under `just`, this is the mounted `bench-results/`. |
| `RUNDIR` | `bench-results-<timestamp>` | The per-run directory inside `OUTBASE`. Set it to a name to label a run (`RUNDIR=before-upgrade`); set it **empty** to write straight into `OUTBASE` rather than a subdirectory. |
| `OUTDIR` | — | Deprecated alias read as a fallback for `OUTBASE`. `OUTDIR=/out` means `/out/bench-results-<timestamp>`. |

### Run structure

| Variable | Default | Meaning |
| --- | --- | --- |
| `REPEATS` | `3` | How many times the whole suite runs. Each pass writes its own results and graphs, and the graphs are additionally aggregated across passes as a mean with the spread behind it. `1` skips the aggregate entirely. |
| `ORDER` | `by-mount` | `by-mount` gives each mount an uninterrupted block of tests. `by-test` runs each test on every mount before moving on, which pairs the mounts closely in time — fairer for a head-to-head when both share hardware. |
| `SETTLE` | `15` | Seconds idle between runs, mounts and passes. `0` disables. |
| `TEST_SETTLE` | `1` | Seconds idle between consecutive tests on one mount, so one job's writeback does not land in the next job's first samples. `0` disables. Not used in `by-test` order, where `SETTLE` already separates every unit. |

`REPEATS` must be a positive integer. `SETTLE` and `TEST_SETTLE` accept `0`;
anything non-numeric silently disables them.

### fio

| Variable | Default | Meaning |
| --- | --- | --- |
| `FIO_SIZE` | `10G` | Working set per fio job. Should exceed RAM for the read tests to reach the storage rather than the page cache. |
| `FIO_RUNTIME` | `60` | Seconds per fio job. Every mount gets equal *time*, not equal *bytes*, so a slow backend cannot shorten its own run. |
| `IOENGINE` | `libaio` | fio ioengine. The commit-latency test overrides this with `psync` regardless, because blocking is what it measures. |
| `LOG_AVG_MSEC` | `100` | Time-series sample window, in milliseconds, and also the bucket width when concurrent jobs' samples are folded together. Going below ~100 is not advised: on slow storage a short window holds too few I/Os to mean anything, and per-job timestamp drift starts landing samples in the wrong bucket. Must be ≥ 1. |

The eight fio jobs are fixed: `seq_write_1m`, `seq_write_zero_1m`,
`seq_write_rand_1m`, `seq_read_1m`, `rand_write_4k`, `rand_read_4k`,
`rand_rw_70_30_4k`, `fsync_8k_qd1`. The report explains what each one measures
and quotes the exact command that ran.

### pgbench

A throwaway PostgreSQL cluster is created on each mount, loaded, warmed and
then driven through pgbench's built-in TPC-B-like workload. The cluster is
deleted afterwards — including on Ctrl-C.

| Variable | Default | Meaning |
| --- | --- | --- |
| `PGBENCH` | `1` | `0` skips the postgres workload entirely. |
| `PGBENCH_SCALE` | `100` | pgbench scale factor. Roughly 16 MiB of table data per point, so 100 is ~1.6 GiB before indexes. Raise it to push the read path past the page cache. |
| `PGBENCH_CLIENTS` | `8` | Concurrent client connections. |
| `PGBENCH_JOBS` | `4` | pgbench worker threads. Must not exceed `PGBENCH_CLIENTS`. |
| `PGBENCH_TIME` | `300` | Seconds of measured run. |
| `PGBENCH_WARMUP` | `30` | Seconds of unmeasured run before it, discarded. Measured from cold, pgbench reports the decay into the workload rather than the workload. `0` measures from cold deliberately. |
| `PGBENCH_MODE` | `prepared` | Query protocol: `simple`, `extended` or `prepared`. pgbench defaults to `simple`, which makes the server reparse and replan every statement — measuring postgres reading SQL rather than the storage under it. |
| `PGBENCH_MAX_WAL` | `4GB` | postgres `max_wal_size`. At the 1 GB default a fast mount checkpoints every few seconds, which is a property of the default rather than of any tuned database. |

`shared_buffers` is deliberately left at its 128 MB default, in the other
direction: a cluster large enough to cache the working set would report the
speed of RAM. `fsync`, `synchronous_commit` and `full_page_writes` are all on.

The workload is skipped, with the reason recorded in the report, if postgres is
not present, if the benchmark is running as root (postgres refuses to), or if
the uid has no `/etc/passwd` entry and one cannot be added.

### Report

| Variable | Default | Meaning |
| --- | --- | --- |
| `PLOT` | `1` | `0` skips the gnuplot graphs. The report says so, and the raw time-series logs are still written. |
| `RENDER` | `html` | `none` writes only the Markdown. The HTML is a single self-contained file with the graphs inlined. |

## Justfile targets

| Target | What it does |
| --- | --- |
| `just bench <paths...>` | Pull the published image and benchmark those paths. Needs only a container engine — **no Nix**. This is the one to run on the storage host. |
| `just run <paths...>` | Build the image from this checkout with Nix, then benchmark. For working on the script. |
| `just smoke` | Tiny end-to-end run against a container-local tmpfs, to prove the image works. Pins its own small settings. |
| `just build` | Build the image tarball with Nix (`./result`). |
| `just load` | Build, then load into the local container engine. |
| `just shell` | Interactive shell inside the image. |
| `just size` | Uncompressed image size and tarball size. |
| `just push [registry]` | Push `:<tag>` and `:latest`. |
| `just clean` | Remove `./result` and the local image. |

All the script variables above are forwarded into the container by `bench` and
`run`, so `FIO_RUNTIME=120 REPEATS=1 just bench /tank/backup` works.

`smoke` does **not** forward them — it pins its own — so use `RUN_ARGS` to
override there: `RUN_ARGS="-e REPEATS=1" just smoke`.

## Justfile variables

Set on the command line (`just tag=v2 push`) or, where noted, in the
environment.

| Variable | Default | Meaning |
| --- | --- | --- |
| `image` | `storage-bench` | Image name. |
| `tag` | dated, e.g. `2026-08-24-r8` | Image tag. |
| `default_registry` | `docker.io/athallerde` | Where `just push` sends the image. |
| `registry` | `default_registry` | Where `just bench` pulls from. Env: `REGISTRY`. |
| `engine` | `docker` | Container engine. Env: `CONTAINER_ENGINE=podman`. |
| `run_args` | empty | Extra engine flags for `run`/`smoke`. Env: `RUN_ARGS="--cpus 4 --network none"`. |
| `results` | `./bench-results` | Where reports are written on the host. |

## Output layout

One directory per run, under `OUTBASE`:

```
bench-results-<timestamp>/
├── storage-benchmark-report.md      the report, readable as-is
├── storage-benchmark-report.html    the same, self-contained, graphs inlined
├── fio_results.csv                  one row per (pass, mount, test)
├── pgbench_results.csv              one row per (pass, mount)
├── graphs/
│   ├── run-01/ run-02/ ...          per-pass charts, plus the .gp that drew them
│   ├── aggregate/                   mean across passes, with the spread behind it
│   ├── compare/                     every pass on one axis, unaggregated
│   └── data/                        the reduced series, for re-plotting
├── fio-logs/run-NN/                 fio's own time-series logs, plus pgbench's
└── raw/
    ├── df_<mount>.txt               per-mount, not per-pass
    ├── mount_<mount>.txt
    └── run-NN/                      fio terse output, pgbench and server logs
```

Every pass gets its own subdirectory because fio names its logs after the test,
not after the attempt.

`storage-bench.nu` writes the same tree with one difference: capacity is
`raw/capacity_<mount>.csv`, a structured table, where the shell version keeps
`df -h` output verbatim in `raw/df_<mount>.txt`.

## How long a run takes

The defaults are deliberately thorough rather than quick. Per mount, per pass:

- eight fio jobs at `FIO_RUNTIME=60` → ~8 minutes
- pgbench load at scale 100, plus a 30s warmup and a 300s measured run → ~6 minutes

At `REPEATS=3` that is roughly **45 minutes per mount**, before `SETTLE`. Two
mounts is an hour and a half.

To cut it down:

```sh
# one pass, shorter jobs, no postgres — minutes rather than an hour
REPEATS=1 FIO_RUNTIME=15 PGBENCH=0 just bench /tank/backup

# keep postgres but make it brief
REPEATS=1 PGBENCH_SCALE=20 PGBENCH_WARMUP=10 PGBENCH_TIME=60 just bench /tank/backup
```

### Free space

Each mount needs room for, at peak:

- **five** fio files of `FIO_SIZE` each — `fio_seq.dat`, `fio_seq_zero.dat`,
  `fio_seq_rand.dat`, `fio_rand.dat`, `fio_mix.dat`
- one `fio_sync.dat` of a fixed 1 GiB
- the pgbench cluster, roughly 16 MiB per `PGBENCH_SCALE` point plus indexes

At the defaults that is **about 53 GiB per path** (`5 × 10G + 1G + ~1.6G`).
Everything is deleted when the run finishes, including on Ctrl-C, but it has to
fit while the run is going. `FIO_SIZE` is the lever:

```sh
FIO_SIZE=2G just bench /tank/backup     # ~12 GiB peak instead
```
