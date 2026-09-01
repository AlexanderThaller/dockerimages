# storage-chaos

Deletes pods in a namespace on a schedule, in a repeatable order, and writes a
timeline of what went when — so a storage benchmark running beside it can be
read against the failures rather than guessed at.

Built to sit next to
[storage-bench](https://hub.docker.com/r/athallerde/storage-bench) during an
OpenShift ODF versus Portworx trial: one container measuring a PVC on each
provider, one container taking the storage pods out from under them.

The image is a Nix closure and nothing else — `kubectl`, `bash`, `gawk`,
`coreutils` and `cmark-gfm`, no distro userland and no package manager. It runs
unprivileged, under an arbitrary uid, and needs no node access.

## Quick start

```sh
# see what it would do, delete nothing — always do this first
docker run --rm -v ~/.kube/config:/kube/config:ro -e KUBECONFIG=/kube/config \
  -e DRY_RUN=1 athallerde/storage-chaos openshift-storage

# ten kills a minute apart, report into ./chaos-results
docker run --rm \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v ~/.kube/config:/kube/config:ro -e KUBECONFIG=/kube/config \
  -v "$PWD/chaos-results:/out" -e OUTBASE=/out \
  -e INCLUDE='/rook-ceph-osd-' \
  athallerde/storage-chaos openshift-storage
```

Arguments are the namespaces to kill pods in. Everything else is an environment
variable, and `--help` prints all of them with their defaults:

```sh
docker run --rm athallerde/storage-chaos --help
```

In cluster it needs no kubeconfig — it picks up the mounted ServiceAccount
token by itself, given a Role allowing `get`, `list` and `delete` on pods in the
target namespace. The manifests are in the source repository under `deploy/`.

## The two modes

`MODE=random` (default) shuffles the candidates and works through them,
reshuffling each cycle. The shuffle is seeded: same `SEED`, same order, so a run
that found something can be run again.

`MODE=deterministic` sorts the candidates and walks the list start to end,
repeating — the same pods in the same order on every run.

Both pick pods by a *key* naming the slot (`ds/<name>@<node>`,
`deploy/<name>@<node>`, `sts/<pod>`) rather than by name, because a replaced pod
comes back under a new name and "the same pod as last cycle" is not something a
name can express.

## Environment variables

| Variable | Default | |
|---|---|---|
| `SELECTOR` | none | Label selector for candidates, e.g. `app=rook-ceph-osd` |
| `INCLUDE` / `EXCLUDE` | none | Regex a `<ns>/<pod>` must / must not match |
| `MODE` | `random` | `random` or `deterministic` |
| `SEED` | `1` | Seeds the shuffle |
| `ITERATIONS` | `10` | Kill rounds; `0` runs until stopped |
| `DURATION` | `0` | Stop after this many seconds; `0` is off |
| `INTERVAL` | `60` | Seconds between rounds |
| `START_DELAY` | `30` | Seconds before the first kill |
| `BATCH` | `1` | Pods deleted per round |
| `KILL_MODE` | `force` | `force` (`--grace-period=0 --force`) or `graceful` |
| `WAIT_READY` | `1` | Wait for the group to recover before the next kill |
| `READY_TIMEOUT` | `300` | How long to wait for that |
| `POLL` | `1` | Seconds between readiness checks |
| `MIN_READY` | `0` | Ready pods a group must keep |
| `DRY_RUN` | `0` | Resolve, log and report; delete nothing |
| `OUTBASE` | `/tmp` | Directory the run directory goes in |
| `LABEL` | none | Appended to the default `RUNDIR` (`LABEL=osd-kills` → `chaos-<ts>-osd-kills`). Ignored if `RUNDIR` is set explicitly. |
| `RUNDIR` | `chaos-<ts>` | This run's directory inside it |
| `REPORT` | `html` | `html`, `md` or `none` |
| `HOLD` | `0` | Seconds to stay alive after the report is written |
| `KUBECTL` | `kubectl` | Client to use; may carry flags |

## Output

One directory per run, mounted out through `/out`:

```
chaos-<timestamp>/
├── events.csv     every event, UTC and epoch, to microseconds
├── chaos.log      the run as it was printed
├── config.env     every tunable this run used, ready to source
├── plan.txt       the configuration and the order pods were to be killed in
├── heatmap.svg    component x time slice, shaded by seconds spent degraded
├── recovery.svg   time to recover per kill, against when it happened
├── histogram.svg  distribution of recovery times, overall and per component
├── timeline.svg   one lane per component, kills and recoveries along time
└── report.html    all of the above, rendered — this is the one to read
```

Every tunable and its value is recorded in `chaos.log`, `plan.txt`,
`config.env` and the report's Configuration section, each marked `set` (came
from the environment) or `default` (the script chose it).

`storage-chaos --replot <dir>` rebuilds the charts and report from a run's own
`events.csv`, `config.env` and `plan.txt`, without a cluster — useful for
rendering a report a first run skipped (`REPORT=none`, or no `cmark-gfm`).

Start both containers at about the same time and correlate on the clock:
everything is UTC, and `elapsed_s` is seconds since the chaos run started — the
same axis a benchmark alongside it can be read on.

Microseconds are not a claim about accuracy. A kill is bracketed by two
timestamps because the DELETE call takes a few hundred milliseconds, and a
recovery is only ever observed at the next poll; the report says both. They are
there so ordering is never ambiguous and so the numbers join against anything
else that logs a clock. The clock is a bash builtin rather than a forked
`date`, because the fork would otherwise sit inside the interval it is timing.

## Safety

This deletes pods in a live cluster and that is its entire purpose. `DRY_RUN=1`
first, `INCLUDE` to keep the blast radius small, `MIN_READY=1` to keep every
component alive, and a namespaced Role so the cluster itself limits where it can
reach. Point it at a cluster that is being tried out, not one holding anything.

## Source

<https://github.com/athaller/dockerimages> — `storage-chaos/`, which also has
the full README, the deployment manifests and `stage-fixture.sh`, a script that
creates throwaway lookalike workloads to rehearse against.
