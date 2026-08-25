# storage-bench

Benchmarks one or more mounted filesystems with **fio** and then with a real
**PostgreSQL/pgbench** workload, and writes a single self-contained HTML report
with time-series graphs. The whole run is tarred up at the end so there is one
file to copy off the machine.

fio tells you what the device can do. pgbench tells you what a database
actually gets out of it — WAL, fsync at commit, checkpoints and full-page
writes included — which is always less, and is the number an application would
recognise.

No distro userland, no package manager: the image is a Nix closure of fio,
gnuplot, postgresql, cmark-gfm and bash — 43 MB compressed, 132 MB on disk.

## Run it

```sh
docker run --rm \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  --shm-size=256m \
  -v /tank/backup:/data/backup \
  -v "$PWD/results":/out -e OUTBASE=/out \
  athallerde/storage-bench:latest /data/backup
```

Every argument after the image is a path **inside the container** to benchmark,
so bind-mount each one and pass its container path. Two paths, head to head:

```sh
docker run --rm \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  --shm-size=256m \
  -v /tank/backup:/data/backup \
  -v /mnt/ceph:/data/ceph \
  -v "$PWD/results":/out -e OUTBASE=/out \
  athallerde/storage-bench:latest /data/backup /data/ceph
```

Results land in `results/bench-results-<timestamp>/`, with
`bench-results-<timestamp>.tar.gz` beside it.

### The flags matter

| Flag | Why |
| --- | --- |
| `--user "$(id -u):$(id -g)"` | **Required for the pgbench half.** PostgreSQL refuses to run as root, so without this the postgres workload is skipped and the report says so. It also keeps the results from being written root-owned. |
| `-v … :/out -e OUTBASE=/out` | Where the report is written. Without it the results stay inside the container and are lost when it exits. |
| `--shm-size=256m` | PostgreSQL puts shared memory segments in `/dev/shm`, which Docker caps at 64 MB. A parallel index build during the pgbench load can exhaust that. |
| `-e HOME=/tmp` | The image's `HOME` is `/root`, which a non-root user cannot write. |

The image runs `storage-bench.sh` as its entrypoint, so a bare
`docker run athallerde/storage-bench` prints usage. To poke at the tools
directly: `docker run --rm -it --entrypoint bash athallerde/storage-bench`.

## Quick run

The defaults are thorough — about 45 minutes per path. To get a feel for it
first:

```sh
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v /tank/backup:/data/backup -v "$PWD/results":/out -e OUTBASE=/out \
  -e REPEATS=1 -e FIO_SIZE=2G -e FIO_RUNTIME=15 -e PGBENCH=0 \
  athallerde/storage-bench:latest /data/backup
```

## Configuration

Everything is an environment variable. There are no command-line flags.

### Output

| Variable | Default | Meaning |
| --- | --- | --- |
| `OUTBASE` | `/tmp` | Directory the run directory is created in. Mount something here. |
| `RUNDIR` | `bench-results-<timestamp>` | Name of the per-run directory. Set it to label a run (`RUNDIR=before-upgrade`); set it **empty** to write straight into `OUTBASE`. |
| `ARCHIVE` | `1` | Tar the finished run directory into `<RUNDIR>.tar.gz`. `0` disables. |

### Run structure

| Variable | Default | Meaning |
| --- | --- | --- |
| `REPEATS` | `3` | Passes over the whole suite. Each pass is charted on its own, and the passes are also aggregated into a mean with the spread drawn behind it, so you can see how much the storage disagreed with itself. `1` skips the aggregate. |
| `ORDER` | `by-mount` | `by-mount` gives each path an uninterrupted block. `by-test` runs each test on every path before moving on, pairing them closely in time — fairer when both share hardware. |
| `SETTLE` | `15` | Seconds idle between runs, paths and passes. |
| `TEST_SETTLE` | `1` | Seconds idle between consecutive tests, so one job's writeback does not land in the next job's first samples. |

### fio

| Variable | Default | Meaning |
| --- | --- | --- |
| `FIO_SIZE` | `10G` | Working set per job. Should exceed RAM for the read tests to reach the storage rather than the page cache. |
| `FIO_RUNTIME` | `60` | Seconds per job. Every path gets equal *time*, not equal *bytes*. |
| `IOENGINE` | `libaio` | fio ioengine. |
| `LOG_AVG_MSEC` | `100` | Time-series sample window in ms. Below ~100 the samples stop being meaningful on slow storage. |

Eight jobs, fixed: `seq_write_1m`, `seq_write_zero_1m`, `seq_write_rand_1m`,
`seq_read_1m`, `rand_write_4k`, `rand_read_4k`, `rand_rw_70_30_4k`,
`fsync_8k_qd1`. The zero and random variants exist to catch backends that
compress or deduplicate — where they diverge, the backend is looking at your
data.

### pgbench

A throwaway PostgreSQL cluster per path: `initdb` on the storage under test,
load, warm up, then the built-in TPC-B-like workload. Deleted afterwards,
including on Ctrl-C.

| Variable | Default | Meaning |
| --- | --- | --- |
| `PGBENCH` | `1` | `0` skips the postgres workload. |
| `PGBENCH_SCALE` | `100` | Scale factor; ~16 MiB of table data per point, so ~1.6 GiB. Raise it to push reads past the page cache. |
| `PGBENCH_CLIENTS` | `8` | Concurrent connections. |
| `PGBENCH_JOBS` | `4` | Worker threads. Must not exceed `PGBENCH_CLIENTS`. |
| `PGBENCH_TIME` | `300` | Seconds measured. |
| `PGBENCH_WARMUP` | `30` | Seconds discarded first. Measured from cold, pgbench reports the decay into the workload rather than the workload. `0` measures from cold deliberately. |
| `PGBENCH_MODE` | `prepared` | `simple`, `extended` or `prepared`. pgbench defaults to `simple`, which measures postgres parsing SQL as much as the storage under it. |
| `PGBENCH_MAX_WAL` | `4GB` | `max_wal_size`. At the 1 GB default a fast path checkpoints every few seconds, which dominates the run. |

`shared_buffers` stays at 128 MB on purpose — a cluster big enough to cache the
working set would report the speed of RAM. `fsync`, `synchronous_commit` and
`full_page_writes` are all on.

### Report

| Variable | Default | Meaning |
| --- | --- | --- |
| `PLOT` | `1` | `0` skips the gnuplot graphs. |
| `RENDER` | `html` | `none` writes only the Markdown. |

## What you get

```
bench-results-<timestamp>.tar.gz     everything below, in one file
bench-results-<timestamp>/
├── storage-benchmark-report.html    self-contained, graphs inlined
├── storage-benchmark-report.md      the same, readable as text
├── fio_results.csv
├── pgbench_results.csv
├── graphs/{run-NN,aggregate,compare}/
├── fio-logs/run-NN/                 fio's own time-series logs
└── raw/                             unparsed fio, pgbench and server output
```

## Disk space

Each path needs room, at peak, for **five** fio files of `FIO_SIZE` each, one
fixed 1 GiB file, and the pgbench cluster — **about 53 GiB per path at the
defaults**. It is all deleted when the run finishes, but it has to fit while
the run is going. `FIO_SIZE=2G` brings that to about 12 GiB.

## How long

Per path, per pass: eight fio jobs at 60s each, plus a pgbench load, 30s warmup
and 300s measured run — roughly 14 minutes. At `REPEATS=3` that is **about 45
minutes per path**. Two paths is an hour and a half.

## Notes

- Runs unprivileged. No `--privileged`, no capabilities, no host network.
- The image ships `/etc/passwd` writable so the script can add an entry for
  whatever uid `--user` gives it; PostgreSQL treats a failed `getpwuid()` as
  fatal and would otherwise refuse to start.
- Skipped work is always explained: if postgres is missing, if it is running as
  root, or if gnuplot is unavailable, the report says so rather than quietly
  omitting a section.

Source, and a Nushell implementation of the same benchmark, at
<https://git.thaller.ws/athaller/dockerimages>.
