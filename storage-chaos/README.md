# storage-chaos

Deletes pods in a namespace on a schedule, in a repeatable order, and writes a
timeline of what went when — so a storage benchmark running beside it can be
read against the failures rather than guessed at.

It was built to sit next to [storage-bench](../storage-bench) during an
OpenShift ODF versus Portworx trial: one container measuring a PVC on each
provider, one container taking the storage pods out from under them.

Everything is configured through environment variables. The only arguments are
the namespaces to kill pods in.

- [Quick start](#quick-start)
- [Arguments](#arguments)
- [The two modes](#the-two-modes)
- [Choosing what dies](#choosing-what-dies)
- [Environment variables](#environment-variables)
- [Output](#output)
- [Reading it against a benchmark](#reading-it-against-a-benchmark)
- [Rehearsing on stage](#rehearsing-on-stage)
- [Running it in the cluster](#running-it-in-the-cluster)
- [Justfile targets](#justfile-targets)
- [Safety](#safety)

## Quick start

```sh
# see what it would do, delete nothing — always do this first
just dry openshift-storage

# the OSD lookalikes only, ten kills a minute apart
INCLUDE='/rook-ceph-osd-' just chaos openshift-storage

# the same pods in the same order every time
MODE=deterministic just chaos portworx

# both providers in one run, for four hours
DURATION=14400 ITERATIONS=0 just chaos openshift-storage portworx

# without the container at all
nix-shell --run './storage-chaos.sh openshift-storage'
```

Reports land in `chaos-results/`, one timestamped directory per run.

## Arguments

```
storage-chaos.sh <namespace> [<namespace> ...]
```

Every argument is a namespace to kill pods in. The only flag is `--help`, which
prints the full environment-variable table; a bare invocation prints the same
thing to stderr. That table is generated from the script's own tunable list, so
it cannot fall out of step with what the script accepts — which is what makes it
the answer for a container, where the script lives in the Nix store and the
header comment is not something anyone is going to `cat`:

```sh
docker run --rm athallerde/storage-chaos --help
```

Everything else is an environment variable.

Under `just chaos` / `just run` the namespaces are passed straight through, and
your kubeconfig is mounted into the container read-only.

## The two modes

`MODE=random` (the default) shuffles the candidate pods and works through them,
reshuffling on each cycle. The shuffle is seeded, so `SEED=7` twice over the
same cluster kills the same pods in the same order — a run that found something
can be run again.

`MODE=deterministic` sorts the candidates and walks the list start to end,
repeating. The same cluster gives the same order on every run and every cycle.

Both choose pods through a **key** rather than a name, because pod names are
not stable — the replacement for a deleted DaemonSet or Deployment pod comes
back with a different random suffix, so "the same pod as last cycle" is not
something a name can express. The key names the slot:

| owner | key | stable across |
|---|---|---|
| DaemonSet | `ds/<name>@<node>` | restarts |
| Deployment | `deploy/<name>@<node>` | restarts and rollouts |
| StatefulSet | `sts/<pod>` | everything |
| unowned | `pod/<name>` | nothing; it is the pod |

The pod holding a slot is resolved again immediately before each kill, and two
pods sharing one — two replicas of a Deployment on one node — are numbered
`#1`, `#2` in name order. A key whose slot is empty when its turn comes is
logged as a skip rather than silently passed over.

So the order is stable for as long as the cluster's shape is. A node added or a
component scaled changes the key set, and therefore the order; `plan.txt` in
the output directory records what a given run actually used.

## Choosing what dies

Candidates are every pod in the given namespaces, narrowed in three steps:

- `SELECTOR` — a label selector, handed to `kubectl -l` verbatim, so set-based
  selectors work: `SELECTOR='app in (rook-ceph-osd,rook-ceph-mon)'`
- `INCLUDE` — a regex a pod's `<namespace>/<pod>` must match
- `EXCLUDE` — a regex it must not

Left wide open, a run kills operators, CSI sidecars and monitoring pods along
with everything else, which is a fine test of the operator and a poor test of
the data path. Start narrow:

```sh
INCLUDE='/rook-ceph-osd-'              # Ceph OSDs
INCLUDE='/(rook-ceph-osd|rook-ceph-mon)-'
INCLUDE='/(px-storage|portworx)-'      # the Portworx daemon
SELECTOR='app=csi-rbdplugin'           # the CSI node plugin
EXCLUDE='operator|noobaa'              # everything except the operators
```

The namespaces themselves are `openshift-storage` for ODF, and `portworx` or
`kube-system` for Portworx depending on how it was installed.

Every pod in the namespace is a candidate by default — `SELECTOR`, `INCLUDE`
and `EXCLUDE` only ever narrow that, so there is nothing to set to widen it
back. `INCLUDE='/'` matches everything and is the same as leaving it unset.

Pods that are already terminating are not candidates: deleting one again is a
no-op that would be reported as a kill, and counting it inflates the plan with
slots that are about to be empty — which is what a run started moments after a
`fixture-down` or a rollout would otherwise see.

### When it says there are no candidates

The message names the cause, and there are four:

```
nothing to kill in chaos-test — no pods at all
nothing to kill in chaos-test — none of the 9 pods are candidates: 9 excluded by SELECTOR, INCLUDE or EXCLUDE
nothing to kill in chaos-test — none of the 2 pods are candidates: 2 already terminating
! cannot list pods in chaos-test: error: You must be logged in to the server (Unauthorized)
```

The same sentence is used mid-run, where a namespace that empties out is worth
waiting on rather than exiting over — a namespace whose pods are all being
rescheduled is exactly the moment a chaos run should keep watching — and it is
recorded as a `no-candidates` row in `events.csv` so a quiet stretch in the
timeline has a reason attached to it.

## Environment variables

### Targeting

| Variable | Default | What it does |
|---|---|---|
| `SELECTOR` | none | Label selector for candidate pods |
| `INCLUDE` | none | Regex a `<ns>/<pod>` must match |
| `EXCLUDE` | none | Regex a `<ns>/<pod>` must not match |

### Order and pacing

| Variable | Default | What it does |
|---|---|---|
| `MODE` | `random` | `random` or `deterministic` |
| `SEED` | `1` | Seeds the shuffle; same seed, same order |
| `ITERATIONS` | `10` | Kill rounds; `0` runs until stopped |
| `DURATION` | `0` | Stop after this many seconds; `0` is off |
| `INTERVAL` | `60` | Seconds between rounds |
| `START_DELAY` | `30` | Seconds before the first kill |
| `BATCH` | `1` | Pods deleted per round |

`ITERATIONS` and `DURATION` are both ceilings; whichever is reached first ends
the run. `START_DELAY` exists so the benchmark beside this has time to get past
its own setup — a kill landing during `initdb` or fio's layout pass shows up as
a slow setup and nothing else.

### The kill

| Variable | Default | What it does |
|---|---|---|
| `KILL_MODE` | `force` | `force` or `graceful` |
| `GRACE` | `30` | Grace period, in `graceful` mode |
| `WAIT_READY` | `1` | Wait for the group to recover before the next kill |
| `READY_TIMEOUT` | `300` | How long to wait for that |
| `POLL` | `1` | Seconds between readiness checks |
| `MIN_READY` | `0` | Ready pods a group must keep |
| `DRY_RUN` | `0` | Resolve, log and report; delete nothing |

`force` is `kubectl delete --force --grace-period=0`: the API object goes
immediately and the kubelet is told to stop the container afterwards, which is
as close to pulling the plug as an API call gets and is what makes the graph
move. `graceful` sends a normal termination, which for a Ceph OSD or a Portworx
daemon is a clean shutdown and a much gentler event — worth running as a
baseline to compare the force kills against, not a substitute for them.

The one thing not to point `force` at is a StatefulSet whose workload cannot
tolerate two instances of one ordinal at once: forcing the pod object away lets
the replacement start before the old container is necessarily gone.

### Output

| Variable | Default | What it does |
|---|---|---|
| `OUTBASE` | `/tmp` | Directory the run directory goes in |
| `RUNDIR` | `chaos-<timestamp>` | This run's directory inside it; empty writes straight into `OUTBASE` |
| `REPORT` | `html` | `html`, `md` or `none` |
| `HOLD` | `0` | Seconds to stay alive after the report is written |
| `KUBECTL` | `kubectl` | Client to use; may carry flags, e.g. `oc --context lab` |

`HOLD` is for the in-cluster case and nothing else. `kubectl cp` copies out of a
*running* container, and a Job whose command has returned has none — so without
it the report is written into an emptyDir that is deleted a moment later.

## Output

```
chaos-<timestamp>/
├── events.csv     every event, UTC and epoch, to microseconds
├── chaos.log      the same run as it was printed
├── config.env     every tunable this run used, ready to source
├── plan.txt       the configuration and the order pods were to be killed in
├── heatmap.svg    component x time slice, shaded by seconds spent degraded
├── recovery.svg   time to recover per kill, against when it happened
├── histogram.svg  distribution of recovery times, overall and per component
├── timeline.svg   one lane per component, kills and recoveries along time
└── report.html    all of the above, rendered — this is the one to read
```

### The four charts

No single chart survives every run length, so the report carries four views of
the same kills.

| Chart | Answers | Scales to |
|---|---|---|
| **heatmap** | which component was down, and roughly when | any `ITERATIONS` |
| **recovery** | did recovery get worse as the run went on | any `ITERATIONS` |
| **histogram** | how long recoveries take, and how much they vary | any `ITERATIONS` |
| **timeline** | what happened to each individual kill | ~50 kills |

The **timeline** is the most direct and the first to fail: past roughly fifty
kills the marks merge into a picket fence and each recovery bar is a pixel or
two. It is still drawn — nothing else names the individual events — and the
report says plainly when it has gone past what it can show.

The **heatmap** is its replacement on a long run. The grid is a fixed size
whatever `ITERATIONS` was, so ten kills and a hundred produce the same shape,
and it keeps the per-component dimension that a single aggregate line would
lose. This is the one to hold against a benchmark's throughput graph.

The **recovery** scatter is the soak-test chart: one mark per kill, y is how
long it took to come back, with the overall median drawn across it. Kills that
never recovered are open triangles pinned to the top of the plot — their
duration is unknown, only that it passed `READY_TIMEOUT`, and dropping them
would take the worst outcomes out of a chart about how bad things got. Kills
that cost the component no readiness at all sit as open circles on the floor.

The **histogram** is the distribution view: one small facet per component over
a shared x axis, plus one for all of them together. It is what separates a
component that is reliably slow from one that is usually fast and occasionally
terrible — a difference a median cannot show, and the reason the per-component
table's mean is not the whole story. Its y axis is per facet, not shared,
because the "all components" row holds every sample and would flatten the rest
to nothing; each row prints its own `n`, median and peak.

Only recoveries are binned. A kill that never came back has no duration to bin
and one that cost the component no readiness was never down, so both are
counted in the row's label rather than folded into the first bucket, where they
would put a spike at zero that no pod ever earned.

Colours mean the same thing in all four — blue is the data, red is a kill and
anything that never came back, gray is the absence of a measurement — and every
status carries a shape and a label as well as a colour. Nothing is green: green
against that red measures ΔE 4.1 under deuteranopia, which is to say
indistinguishable.

### What the run was configured with

Every tunable and its effective value is recorded four times over, because the
question a report has to survive is "what were the settings" asked a week
later: in `chaos.log` under `=== Configuration ===`, in `plan.txt`, in the
report's own **Configuration** section, and in `config.env`.

Each is marked `set` or `default` — `set` means the value came from the
environment, `default` means the script chose it. That distinction is what
keeps an old report readable after a default changes: without it there is no
way to tell a deliberate `INTERVAL=60` from one that happened to be the default
at the time.

`config.env` is the machine-readable copy, quoted so it survives values with
spaces or apostrophes, and it re-runs in any POSIX shell:

```sh
cd chaos-results/chaos-20260831-084500
set -a; . ./config.env; set +a; unset RUNDIR
./storage-chaos.sh chaos-test
```

`RUNDIR` is unset so the repeat lands in its own directory rather than
overwriting the run being repeated.

`events.csv` is the machine-readable half and the only input the report reads:

| column | |
|---|---|
| `iso_utc` | `2026-08-31T09:14:02.918273Z` |
| `epoch_ns` | the same instant as epoch nanoseconds, to microsecond resolution |
| `elapsed_s` | seconds since the run started, to the millisecond |
| `round` | which kill round it belongs to |
| `event` | `kill-request`, `kill-done`, `recovered`, `skip`, … |
| `namespace` `pod` `node` | what was killed and where |
| `group` | the workload it belongs to, e.g. `openshift-storage/deploy/rook-ceph-osd-3` |
| `key` | the slot, as above |
| `detail` | free text: how long the delete call took, ready counts |

## Reading it against a benchmark

Start both containers at about the same time and correlate on the clock.
Everything here is UTC, and `elapsed_s` is seconds since the chaos run started
— the same axis a benchmark started alongside it can be read on. Every kill
mark should sit at the front of whatever the benchmark's throughput graph does
next.

Two things bound the numbers, and the report says so rather than hiding it:

- A kill is recorded twice, when the delete was requested and when the API call
  returned. The pod stopped serving somewhere in between; the table shows the
  request time and the call's duration, usually a few hundred milliseconds.
- A recovery is only ever observed at the next poll, so every recovery time is
  accurate to `POLL` seconds and biased late by up to that much.

Microseconds are not a claim about accuracy. They are there so that ordering is
never ambiguous — two events in the same second stay in the order they happened
— and so the numbers can be joined against anything else that logs a clock.

The clock is read with bash's `EPOCHREALTIME` into a variable, not by forking
`date` and not by capturing anything. That matters because two reads bracket
every `kubectl delete`, so whatever the read costs lands *inside* the interval
being measured. Per call, measured in the image:

| | |
|---|---:|
| `date -u`, captured with `< <(...)` | 1082 µs |
| `EPOCHREALTIME`, still captured with `< <(...)` | 341 µs |
| `EPOCHREALTIME` into a variable with `printf -v` | **36 µs** |

The middle row is the one worth noticing: dropping `date` only got a third of
the way there, because *capturing* a bash function's output forks a subshell
whatever is inside it. Writing straight into a global with `printf -v` is the
only form that forks nothing.

So resolution drops from nanoseconds to microseconds and accuracy improves
about thirtyfold — the right way round for a timestamp whose job is to line up
against a graph, since the nanosecond digits were always well inside the
millisecond of overhead that produced them. `epoch_ns` keeps its name and its
19 digits; the last three are now always zero.

A group that never loses a ready pod is reported as **no drop**, which is a
real result rather than a failure to measure: the kill did not cost that
component its readiness at all, and if the benchmark also shows nothing, that
is the answer.

## Rehearsing on stage

`stage-fixture.sh` creates throwaway workloads that look enough like a storage
provider to try all of this against, without going near ODF or Portworx. It is
not in the container image and is not meant to be.

```sh
just fixture-up chaos-test          # or: ./stage-fixture.sh up chaos-test
just chaos chaos-test
just fixture-down chaos-test
```

It creates one Deployment per fake OSD, a DaemonSet, and a StatefulSet of three
— between them every owner kind a key is built from. The pods sleep and go
ready `READY_AFTER` seconds (default 20) after they start, which is the point:
every recovery on the timeline should come out a little over that number. If
they do, the same run against `openshift-storage` is measuring what it says it
is.

| Variable | Default | |
|---|---|---|
| `OSDS` | `3` | Single-replica Deployments to create |
| `MONS` | `3` | StatefulSet replicas |
| `PLUGIN` | `1` | Whether to create the DaemonSet |
| `READY_AFTER` | `20` | Seconds a pod takes to become ready |
| `IMAGE` | `ubi9/ubi-minimal` | Anything with a shell and `sleep` |
| `RUN_AS_USER` | from the namespace | The uid the pods run as; see below |

`RUN_AS_USER` is worked out from the namespace's
`openshift.io/sa.scc.uid-range` annotation and only needs setting to override
that. The uid has to be a real number in the manifest rather than left to the
cluster: `runAsNonRoot: true` with no `runAsUser` is a promise the *kubelet*
checks against the image's own USER, and `ubi-minimal`'s is root — so the pods
die at start with

```
Error: container has runAsNonRoot and image will run as root
```

On OpenShift that is normally hidden, because the restricted-v2 SCC fills the
uid in during admission. It does not always: a ServiceAccount bound to an SCC
with `RunAsAny` — `anyuid`, `privileged` — is admitted by that one instead,
which injects nothing. Taking the first uid of the namespace's own range means
the pods are admitted by restricted-v2 unchanged, cannot be rejected as out of
range, and still work on a cluster with no SCCs at all.

The chaos image itself has the same problem and solves it once, at build time:
`default.nix` sets `User = "1000"` in the image config, because `dockerTools`
otherwise leaves it as root. Anything that cares — an SCC's injected uid, a pod
spec, `docker run --user` — still overrides it.

## Running it in the cluster

Beside the benchmark rather than across the internet from it:

```sh
just deploy openshift-storage
oc -n storage-chaos logs -f job/storage-chaos
```

That applies `deploy/rbac.yaml` — a ServiceAccount, and a **Role** per target
namespace allowing `get`, `list` and `delete` on pods — and `deploy/job.yaml`.
A namespaced Role rather than the cluster-wide pair is deliberate: the blast
radius becomes a property of the cluster rather than of an environment variable
somebody set correctly, and a run meant only for `openshift-storage` cannot be
pointed at `kube-system` by a typo in `INCLUDE`.

The Job sets `HOLD=3600`, so when the run ends the pod stays up for an hour and
the report can be copied out:

```sh
pod=$(oc -n storage-chaos get pod -l job-name=storage-chaos -o name | head -1)
oc -n storage-chaos cp "${pod#pod/}":/out ./chaos-results
just undeploy openshift-storage
```

## Justfile targets

| Target | |
|---|---|
| `just dry <ns>` | Resolve the plan and report on it, delete nothing |
| `just chaos <ns>` | Run with the published image (no build, no Nix) |
| `just run <ns>` | Build from this checkout first, then run |
| `just build` / `load` | Build the image tarball / load it into the engine |
| `just shell` | Interactive shell in the image |
| `just fixture-up <ns>` | Create the rehearsal workloads |
| `just fixture-status <ns>` | Show them the way a chaos run sees them |
| `just fixture-down <ns>` | Delete them again |
| `just deploy <ns>` | Apply the RBAC and the Job in the cluster |
| `just undeploy <ns>` | Take them away again |
| `just size` | Image and tarball size |
| `just push [registry]` | Push `:<tag>` and `:latest` |
| `just clean` | Drop `result` and the local image |

Script tunables are forwarded into the container, so
`MODE=deterministic INTERVAL=120 just chaos portworx` works.

## Why everything is a function

Both scripts define only functions at the top level and end with `main "$@"`.
That is not style. Bash reads a script incrementally — parse a command, run it,
seek on — so a script that is edited, `scp`ed over or `git pull`ed **while it is
running** leaves bash reading from a byte offset that now lands in the middle of
something else. A chaos run can last hours; that is a long time to hold a file
still.

What comes out is a syntax error on a line that was fine when the run started:

```
./storage-chaos.sh: line 1664: unexpected EOF while looking for matching `"'
./storage-chaos.sh: line 1133: syntax error near unexpected token `||'
```

Both were seen here, and neither was a bug in the file.

The quieter failure is worse. Rewriting the script mid-run under the old
structure produced this: four pods killed, then bash reached what it thought was
end-of-file, **exited 0, and wrote no report at all** — a successful-looking run
that silently stopped a third of the way through. Reaching `main "$@"` obliges
bash to have parsed every line above it first, so a run that has started is
running from memory and cannot be affected by the file changing underneath it.

The rule that follows: no statement with an effect belongs at the top level.
Plain assignments of constants are fine and stay where they read best. The one
trap when moving top-level code into a function is that `declare` inside a
function makes a *local* — every default has to be `declare -g` or it is
discarded the moment the function returns.

## Safety

This deletes pods in a live cluster and that is its entire purpose, so there is
no mode in which it is safe. There are only these brakes:

- **`WAIT_READY`** (on by default) — the next kill waits until the group is
  back to the ready count it had before the last one. This is the important
  one: without it `INTERVAL` alone decides how many pods of a component can be
  down at once, and on a slow recovery that is all of them.
- **`MIN_READY`** — refuses a kill that would leave a group with fewer than
  this many ready pods. `1` keeps every component alive; the default `0`
  permits killing a singleton, which for a Ceph mgr or a single-node Portworx
  is the only way to test it at all.
- **`INCLUDE` / `EXCLUDE`** — the blast radius, and the only one of these that
  is set before anything has been deleted.
- **`DRY_RUN`** — resolves, logs, paces and reports; deletes nothing.
- **The namespaced Role** — the cluster's own opinion about where this may run.

Point it at a cluster that is being tried out, not one holding anything.
