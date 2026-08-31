#!/usr/bin/env bash
#
# storage-chaos.sh — delete pods in a namespace on a schedule, and write a
#                    timeline of what was killed when, so a benchmark running
#                    beside it can be read against the failures.
#
# Usage:
#   ./storage-chaos.sh openshift-storage
#   ./storage-chaos.sh portworx
#   ./storage-chaos.sh openshift-storage portworx        # both at once
#   MODE=random SEED=7 ./storage-chaos.sh openshift-storage
#   INCLUDE='^rook-ceph-osd-' ./storage-chaos.sh openshift-storage
#
# The intended shape of a run is two containers side by side: storage-bench
# measuring a PVC on each provider, this one deleting the pods underneath it.
# Neither talks to the other. They are correlated afterwards through wall-clock
# time, which is the whole reason for the timestamps below — every event is
# recorded as UTC and as an epoch offset, both to microsecond resolution, and
# the report lays them out as a timeline whose x axis is seconds since the run
# started. Line that up against the benchmark's own time-series graphs and the
# dip has a cause next to it.
#
# The small units are not a claim about accuracy. What bounds a measurement
# here is elsewhere: a kill is bracketed by two timestamps because the DELETE
# call itself takes a few hundred milliseconds, and a recovery is only ever
# observed as early as the next poll, POLL seconds later. The report says both.
# Microseconds are there so that ordering is never ambiguous — two events in
# the same second stay in the order they happened — and so the numbers can be
# joined against anything else that logs a clock.
#
# The epoch column is still in nanoseconds, and is still called epoch_ns; its
# last three digits are simply always zero. See now() for why that is an
# improvement on the nanosecond clock it replaced.
#
# What gets killed:
#   Every pod in the given namespaces, narrowed by SELECTOR (a label selector,
#   passed to kubectl verbatim), then by INCLUDE and EXCLUDE (regexes over
#   <namespace>/<pod>). Nothing is special-cased per provider: for ODF that is
#   `openshift-storage`, for Portworx `portworx` or `kube-system`, and
#   INCLUDE is what narrows either one to a single component:
#
#     INCLUDE='^openshift-storage/rook-ceph-osd-'      Ceph OSDs only
#     INCLUDE='/(px-storage|portworx)-'                the Portworx daemon only
#     SELECTOR='app in (rook-ceph-osd,rook-ceph-mon)'  by label instead
#
#   Left wide open, a run kills operators, CSI sidecars and monitoring pods
#   too, which is a fine test of the operator and a poor test of the data path.
#   Start narrow.
#
# Modes (MODE):
#   random (default)   a seeded shuffle. The same SEED over the same candidate
#                      pods reproduces the same order, so a run that found
#                      something can be run again. Each cycle reshuffles, with
#                      SEED+cycle, so pods are not hit in a fixed rhythm.
#   deterministic      the same pods in the same order on every cycle and on
#                      every run against the same cluster: keys sorted, walked
#                      start to end, repeat.
#
# Both modes choose pods through a *key* rather than a name, because pod names
# are not stable — the replacement for a deleted DaemonSet or Deployment pod
# comes back with a different random suffix, so "the same pod as last cycle" is
# not something a name can express. The key names the slot instead: the
# DaemonSet or Deployment and the node it runs on, or the StatefulSet pod's own
# (stable) name. The pod holding that slot is resolved again immediately before
# each kill, and two pods sharing a slot get a #1/#2 suffix in name order.
#
# So the deterministic order is stable for as long as the cluster's shape is; a
# node added or a component scaled changes the key set. plan.txt in the output
# directory records the order a given run actually used, and the report repeats
# it.
#
# Safety, such as it is. This deletes pods in a live cluster and that is its
# entire purpose, so there is no mode in which it is safe — there are only
# these brakes:
#
#   WAIT_READY (default on)  the next kill waits until the killed pod's group
#                            is back to the ready count it had before. This is
#                            the important one: without it INTERVAL alone
#                            decides how many pods of a component can be down
#                            at once, and on a slow recovery that is all of
#                            them.
#   MIN_READY  (default 0)   refuse a kill that would leave a group with fewer
#                            than this many ready pods. 1 keeps every component
#                            alive; 0 permits killing a singleton, which for a
#                            Ceph mgr or a single-node Portworx is the only way
#                            to test it at all.
#   INCLUDE / EXCLUDE        the blast radius, and the only one of these three
#                            that is set before anything has been deleted.
#   DRY_RUN    (default 0)   resolve, log, pace and report; delete nothing.
#
# A group is a namespace plus an owning workload — one DaemonSet, one
# Deployment — which is what "the component recovered" is asked about, and what
# MIN_READY counts.
#
# Point it at a cluster that is being tried out, not one holding anything.
#
# Tunables (env vars):
#   Declared once, in TUNABLE_SPEC below, which is also what `--help` prints
#   and what the run's own report and config.env are built from. That list used
#   to be repeated here, in the defaults block and in usage(); the copies drifted.
#   Run the script with no arguments, or --help, to see all of them.
#
# HOLD exists for the in-cluster case and nothing else. `kubectl cp` copies out
# of a *running* container, and a Job whose command has returned has none — so
# the report would be written into an emptyDir that is deleted a moment later.
# Holding the pod open for an hour after the run is what makes the report
# reachable; deploy/job.yaml sets it, and a run on a laptop wants it at 0.
#
# KILL_MODE=force is `kubectl delete --force --grace-period=0`: the API object
# goes immediately and the kubelet is told to stop the container afterwards,
# which is as close to pulling the plug as an API call gets and is what makes
# the graph move. `graceful` sends the pod a normal termination instead, which
# for a Ceph OSD or a Portworx daemon is a clean shutdown and a much gentler
# event — worth running as a baseline to compare the force kills against, not a
# substitute for them.
#
# The one thing not to point `force` at is a StatefulSet whose workload cannot
# tolerate two instances of one ordinal at once: forcing the pod object away
# lets the replacement start before the old container is necessarily gone.
#
# Runs unprivileged and needs no node access. What it does need is a
# ServiceAccount that may get/list pods and delete them in the target
# namespaces — see deploy/rbac.yaml. Out of cluster it uses whatever KUBECONFIG
# points at; in cluster it picks up the mounted ServiceAccount token itself.

set -uo pipefail

# LC_ALL is not only about message text here: $EPOCHREALTIME, which now() takes
# every timestamp from, writes its decimal point in the locale's notation, and
# a comma would silently break the substitutions that split it. TZ is what
# makes bash's own printf %()T render UTC without a `date -u` to ask.
export LC_ALL=C TZ=UTC

# Every tunable: its name, its default, and what it does. The single place any
# of that is written down.
#
# Four things are built from this — the defaults applied below, the `--help`
# text, the config dump in the log and report, and config.env — because they
# were four separate lists before and a tunable added to one was silently
# missing from the others.
#
# `|` rather than a tab as the separator: tab is IFS whitespace, so bash's
# `read` collapses the two around an empty default and shifts the description
# into the default's column.
#
# OUTBASE and RUNDIR carry their defaults here only as documentation — the real
# ones are computed below, because OUTBASE honours the legacy OUTDIR spelling
# and RUNDIR distinguishes unset from deliberately empty.
TUNABLE_SPEC=(
  "OUTBASE|/tmp|directory the run directory goes in"
  "RUNDIR|chaos-<timestamp>|run dir inside it; empty writes into OUTBASE"
  "SELECTOR||label selector for candidate pods"
  "INCLUDE||regex a <namespace>/<pod> must match"
  "EXCLUDE||regex a <namespace>/<pod> must not match"
  "MODE|random|kill order: random or deterministic"
  "SEED|1|seed for random mode; same seed, same order"
  "ITERATIONS|10|kill rounds; 0 runs until stopped"
  "DURATION|0|stop after N seconds; 0 is off"
  "INTERVAL|60|seconds between rounds"
  "START_DELAY|30|seconds before the first kill"
  "BATCH|1|pods deleted per round"
  "KILL_MODE|force|force (--grace-period=0) or graceful"
  "GRACE|30|grace period, seconds; graceful mode only"
  "WAIT_READY|1|1|0, wait for the group to recover"
  "READY_TIMEOUT|300|seconds to wait for that"
  "POLL|1|seconds between readiness checks"
  "MIN_READY|0|ready pods a group must be left with"
  "DRY_RUN|0|1|0, resolve and report, delete nothing"
  "REPORT|html|html, md or none"
  "HOLD|0|seconds to stay alive after the report"
  "KUBECTL|kubectl|client to use; may carry flags"
)

# Name, default and description out of one spec line. The description is the
# remainder rather than a third field, so a description may contain `|` — which
# several do, writing the 1|0 flags the way the reader expects to type them.
spec_parts() { # <spec> -> sets SPEC_NAME SPEC_DEF SPEC_DESC
  SPEC_NAME="${1%%|*}"
  local rest="${1#*|}"
  SPEC_DEF="${rest%%|*}"
  SPEC_DESC="${rest#*|}"
}

TUNABLES=()
for _spec in "${TUNABLE_SPEC[@]}"; do
  spec_parts "$_spec"
  TUNABLES+=("$SPEC_NAME")
done
unset _spec

# Printed on a bare invocation and by --help. The environment table is
# generated from TUNABLE_SPEC rather than written out, so it cannot describe a
# tunable the script no longer has, or miss one it grew.
#
# This matters more than it looks: in the container the script lives in the Nix
# store and the header comment is not something anyone is going to `cat`, so
# for most users this text is the whole documentation.
usage() {
  cat <<'USAGE'
storage-chaos — delete pods in a namespace on a schedule, and report a timeline
                of what went when, so a benchmark running beside it can be read
                against the failures.

Usage: storage-chaos.sh <namespace> [<namespace> ...]

  storage-chaos.sh openshift-storage
  storage-chaos.sh openshift-storage portworx
  DRY_RUN=1 storage-chaos.sh openshift-storage
  MODE=deterministic storage-chaos.sh portworx
  INCLUDE='/rook-ceph-osd-' storage-chaos.sh openshift-storage

Every pod in the given namespaces is a candidate. SELECTOR, INCLUDE and EXCLUDE
only narrow that; there is nothing to set to widen it. Pods already terminating
are never candidates.

Environment variables:
USAGE
  local spec
  for spec in "${TUNABLE_SPEC[@]}"; do
    spec_parts "$spec"
    printf '  %-14s %-18s %s\n' "$SPEC_NAME" "${SPEC_DEF:-(none)}" "$SPEC_DESC"
  done
  cat <<'USAGE'

Order:
  MODE=random (the default) shuffles the candidates and works through them,
  reshuffling each cycle; the shuffle is seeded, so the same SEED over the same
  pods reproduces the same order. MODE=deterministic sorts them and walks the
  list start to end, repeating. Both address pods by the slot they occupy — the
  DaemonSet or Deployment and its node, or the StatefulSet pod's own name —
  because a replaced pod comes back under a new random name.

Stopping:
  ITERATIONS and DURATION are both ceilings; whichever is reached first ends the
  run. SIGINT or SIGTERM ends it at the current round and still writes the
  report.

Safety — this deletes pods in a live cluster, which is its whole purpose:
  WAIT_READY  the next kill waits for the group to regain its ready count. The
              important one: without it INTERVAL alone decides how many pods of
              a component can be down at once.
  MIN_READY   refuses a kill that would leave a group below this many ready
              pods. 1 keeps every component alive; 0 permits killing a singleton.
  INCLUDE     the blast radius, and the only brake set before anything is gone.
  DRY_RUN     resolves, logs, paces and reports; deletes nothing.

Output — one directory per run, under OUTBASE:
  events.csv    every event, UTC and epoch, to microsecond resolution
  chaos.log     the run as it was printed, including the full configuration
  config.env    the same configuration, ready to source and re-run
  plan.txt      the configuration and the order pods were to be killed in
  heatmap.svg   component x time slice, shaded by seconds spent degraded
  recovery.svg  time to recover per kill, against when it happened
  histogram.svg distribution of recovery times, overall and per component
  timeline.svg  one lane per component, kills and recoveries along time
  report.html   all of the above, rendered — this is the one to read

Needs a ServiceAccount that may get, list and delete pods in the target
namespaces. Out of cluster it uses KUBECONFIG; in cluster it finds the mounted
token itself.
USAGE
}

# Argument parsing, defaults and validation. A function, like everything else
# with an effect, so that nothing runs until main() is reached at the very
# bottom — see the note there.
init_config() {
  # --help goes to stdout and exits 0, because it was asked for; the same text on
  # a bare invocation goes to stderr and exits 1, because that is a usage error.
  case "${1:-}" in
  -h | --help | help)
    usage
    exit 0
    ;;
  esac

  NAMESPACES=("$@")
  [ ${#NAMESPACES[@]} -eq 0 ] && {
    usage >&2
    exit 1
  }

  # Which of them the caller actually set, recorded before the defaults below
  # overwrite the distinction. A run is only reproducible if you can tell what
  # was asked for from what was merely not objected to — and when a default
  # changes between versions, this is the only record that says whether a given
  # run was relying on it.
  #
  # ${!v+x} rather than ${!v:-}: RUNDIR= set to empty is a deliberate choice (it
  # writes straight into OUTBASE) and has to count as set.
  # -g on both declares in this function: `declare` inside a function makes a
  # *local*, so without it every default and the whole CONFIG_SET map would be
  # discarded the moment init_config returned. That is the one trap in moving
  # top-level code into a function, and it fails loudly — `KUBECTL[0]: unbound
  # variable` — rather than quietly, which is the only mercy in it.
  declare -gA CONFIG_SET
  for v in "${TUNABLES[@]}"; do
    [ -n "${!v+x}" ] && CONFIG_SET["$v"]=1
  done
  unset v

  TS="$(date -u +%Y%m%d-%H%M%S)"

  # Split the way storage-bench.sh splits it, and for the same reason: OUTBASE is
  # the volume and stays put, RUNDIR is per-run and carries the timestamp, so a
  # second run sits beside the first rather than overwriting it.
  OUTBASE="${OUTBASE:-${OUTDIR:-/tmp}}"
  RUNDIR="${RUNDIR-chaos-$TS}"
  OUTDIR="$OUTBASE${RUNDIR:+/$RUNDIR}"

  # Defaults, applied from TUNABLE_SPEC. OUTBASE and RUNDIR are already set
  # above and are skipped: theirs are computed, not literals.
  #
  # `${!n:-}` and not `${!n+x}`: an empty value takes the default, which is what
  # `SELECTOR="${SELECTOR:-}"` did before this loop replaced it. That matters in
  # the cluster, where deploy/job.yaml passes every tunable through and the ones
  # nobody set arrive as empty strings rather than as absent.
  for _spec in "${TUNABLE_SPEC[@]}"; do
    spec_parts "$_spec"
    case "$SPEC_NAME" in
    OUTBASE | RUNDIR) continue ;;
    esac
    [ -n "${!SPEC_NAME:-}" ] || declare -g "$SPEC_NAME=$SPEC_DEF"
  done
  unset _spec

  read -r -a KUBECTL <<<"${KUBECTL:-kubectl}"

  # As an array, because a set-based selector has spaces in it —
  # `app in (rook-ceph-osd,rook-ceph-mon)` — and an unquoted `${SELECTOR:+-l
  # "$SELECTOR"}` would word-split it into four arguments that kubectl rejects.
  SEL_ARGS=()
  [ -n "${SELECTOR:-}" ] && SEL_ARGS=(-l "$SELECTOR")

  case "$MODE" in
  random | deterministic) ;;
  *)
    echo "MODE must be 'random' or 'deterministic' (got '$MODE')" >&2
    exit 1
    ;;
  esac

  case "$KILL_MODE" in
  force | graceful) ;;
  *)
    echo "KILL_MODE must be 'force' or 'graceful' (got '$KILL_MODE')" >&2
    exit 1
    ;;
  esac

  case "$REPORT" in
  html | md | none) ;;
  *)
    echo "REPORT must be 'html', 'md' or 'none' (got '$REPORT')" >&2
    exit 1
    ;;
  esac

  # Every numeric tunable ends up in arithmetic or in `sleep`, and a typo in one
  # is otherwise found halfway into a run, as a shell error inside a loop that
  # then carries on with the empty string.
  for v in SEED ITERATIONS DURATION INTERVAL START_DELAY BATCH GRACE \
    READY_TIMEOUT POLL MIN_READY HOLD; do
    case "${!v}" in
    '' | *[!0-9]*)
      echo "$v must be a non-negative integer (got '${!v}')" >&2
      exit 1
      ;;
    esac
  done
  [ "$BATCH" -ge 1 ] || {
    echo "BATCH must be at least 1" >&2
    exit 1
  }
  [ "$POLL" -ge 1 ] || {
    echo "POLL must be at least 1 second" >&2
    exit 1
  }
}

# The run directory, the files in it, and the scratch directory. Split from
# init_config because it creates things, and a usage error should not leave an
# empty run directory behind.
init_output() {
  mkdir -p "$OUTDIR" || {
    echo "cannot create output directory $OUTDIR" >&2
    exit 1
  }
  EVENTS="$OUTDIR/events.csv"
  LOGFILE="$OUTDIR/chaos.log"
  PLANFILE="$OUTDIR/plan.txt"

  TMP="$(mktemp -d "${TMPDIR:-/tmp}/storage-chaos.XXXXXX")" || exit 1
  CAND="$TMP/candidates"

  # Truncated again before every round; created here so wait_for_recovery
  # can test it with -s from the first round onwards.
  : >"$TMP/wait"
}


# --------------------------------------------------------------------------
# Clock and logging
# --------------------------------------------------------------------------

# Both representations of one instant, taken without forking anything, into
# NOW_ISO and NOW_NS. Callers do `now; a=$NOW_ISO b=$NOW_NS`.
#
# Globals rather than a return value because there is no way to *capture* a
# bash function's output that does not fork: `$(now)` forks a subshell and a
# pipe, `< <(now)` forks a subshell, and either one costs an order of magnitude
# more than everything this function does. `printf -v` writes straight into a
# variable and forks nothing.
#
# This used to be a single `date -u +'...%N %s%N'`, which read a clock with
# genuine nanosecond resolution — and cost 936us a call to do it, measured on
# the machine this was written on. That mattered more than the resolution did,
# because two of these bracket every `kubectl delete`: the fork sat *inside*
# the interval being measured, inflating every reported call duration by about
# 2ms and putting up to 1ms between the recorded kill time and the kill. Digits
# below a millisecond were noise dressed as precision.
#
# $EPOCHREALTIME is a bash builtin with microsecond resolution and no fork, at
# 36us a call including the printf. The number is a thousand times coarser and
# about thirty times closer to the truth, which is the right trade for a
# timestamp whose job is to line up against a benchmark graph.
#
# The epoch field stays in nanoseconds, and stays 19 digits, so events.csv from
# before and after this change are the same format — the last three digits are
# now always zero, which is what a microsecond clock honestly has to say.
# Ordering, the other reason for the small units, is untouched: consecutive
# reads still come back distinct.
#
# Measured in the image, per call: 1082us forking `date` and capturing it,
# 341us for the builtin still captured through a process substitution, 36us
# for the form below. The middle number is why the capture had to go too.
NOW_ISO=""
NOW_NS=""
now() { # -> sets NOW_ISO, NOW_NS
  local t=$EPOCHREALTIME
  NOW_NS="${t/./}000"
  printf -v NOW_ISO '%(%Y-%m-%dT%H:%M:%S)T.%sZ' "${t%.*}" "${t#*.}"
}

# The instant the run is measured from, and the origin of every elapsed_s in
# the report. Taken from main() rather than here, both so nothing executes at
# the top level and because it is more honest: the run starts when the run
# starts, not when bash finished reading the script.
START_ISO=""
START_NS=""
mark_start() {
  now
  START_ISO="$NOW_ISO"
  START_NS="$NOW_NS"
}

# Seconds since the run started, to milliseconds — the x axis of the report and
# of anything else the run is being read against. Integer arithmetic rather
# than a fork per event: epoch nanoseconds is 19 digits and bash arithmetic is
# 64-bit, which leaves three centuries of headroom.
elapsed() { # <epoch ns>
  local d=$((($1 - START_NS) / 1000000))
  printf '%d.%03d' $((d / 1000)) $((d % 1000))
}

log() { printf '\n=== %s ===\n' "$*" | tee -a "$LOGFILE"; }
info() { printf '  %s\n' "$*" | tee -a "$LOGFILE"; }
warn() { printf '  ! %s\n' "$*" | tee -a "$LOGFILE" >&2; }

# The machine-readable half of the output, and the only input the report reads.
# Anything worth putting in the timeline goes through here.
#
# The timestamp is an argument rather than being taken here, because the events
# that matter most are the ones bracketing a `kubectl delete` — taking the
# clock inside this function would put the round trip inside the measurement.
event() { # <iso> <epoch ns> <round> <event> <ns> <pod> <node> <group> <key> <detail>
  local iso="$1" ns="$2" round="$3" kind="$4" namespace="$5" pod="$6" node="$7"
  local group="$8" key="$9" detail="${10}"
  # Commas would put the detail into the next column; nothing here needs to
  # carry one, so they become semicolons rather than dragging CSV quoting into
  # a file that is otherwise flat.
  detail="${detail//,/;}"
  detail="${detail//$'\n'/ }"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$iso" "$ns" "$(elapsed "$ns")" "$round" "$kind" "$namespace" "$pod" \
    "$node" "$group" "$key" "$detail" >>"$EVENTS"
}

init_events() {
  printf 'iso_utc,epoch_ns,elapsed_s,round,event,namespace,pod,node,group,key,detail\n' \
    >"$EVENTS"
}

# --------------------------------------------------------------------------
# Shutdown
# --------------------------------------------------------------------------

STOP=0
STOP_REASON=""
SIGNALS=0

# A container is stopped with a signal, and the report is the point of the run,
# so the signal has to reach the loop rather than the process. It sets a flag;
# nap() and the loop check it, the run ends where it is and the report is
# written from the events that did happen.
on_signal() {
  STOP=1
  SIGNALS=$((SIGNALS + 1))
  STOP_REASON="signal"
  printf '\n  ! signal received, finishing the current round\n' >&2
}

cleanup() { rm -rf "$TMP"; }

# Installed from main(), not at the point of definition: a trap set while
# bash is still reading the file would fire against a half-parsed script.
init_traps() {
  trap on_signal INT TERM
  trap cleanup EXIT
}

# Sleeping in one-second steps rather than one long `sleep`: bash runs a trap
# only once the foreground command it interrupted has finished, so a plain
# `sleep 60` would sit on a SIGTERM for up to a minute before noticing it.
nap() { # <seconds>
  local left="$1"
  while [ "$left" -gt 0 ] && [ "$STOP" -eq 0 ]; do
    sleep 1
    left=$((left - 1))
  done
}

# --------------------------------------------------------------------------
# Cluster
# --------------------------------------------------------------------------

kc() { "${KUBECTL[@]}" "$@"; }

# Everything the key and the group are built from, in one request per
# namespace. custom-columns rather than JSON keeps jq out of the image; the
# output is whitespace-separated with `<none>` for anything absent, which is
# exactly what awk wants.
POD_COLUMNS='NAME:.metadata.name,NODE:.spec.nodeName,KIND:.metadata.ownerReferences[0].kind,OWNER:.metadata.ownerReferences[0].name,PHASE:.status.phase,READY:.status.conditions[?(@.type=="Ready")].status,DEL:.metadata.deletionTimestamp'

preflight() {
  command -v "${KUBECTL[0]}" >/dev/null 2>&1 || {
    echo "${KUBECTL[0]} not found on PATH" >&2
    exit 1
  }

  local ns fatal=0
  for ns in "${NAMESPACES[@]}"; do
    if ! kc get pods -n "$ns" --no-headers >/dev/null 2>"$TMP/err"; then
      warn "cannot list pods in $ns: $(tr -d '\n' <"$TMP/err")"
      fatal=1
      continue
    fi
    # Asked rather than discovered by a failing delete halfway through the run,
    # which is a report of nine kills and one silent hole in the timeline.
    if [ "$DRY_RUN" -eq 0 ] &&
      [ "$(kc auth can-i delete pods -n "$ns" 2>/dev/null)" != "yes" ]; then
      warn "not allowed to delete pods in $ns — see deploy/rbac.yaml"
      fatal=1
    fi
  done
  [ "$fatal" -eq 0 ] || exit 1
}

# Ready pods per group, as of the last listing.
#
# This was an awk over the candidate file per group per poll. wait_for_recovery
# polls every POLL seconds for up to READY_TIMEOUT, so a slow recovery of three
# groups was running a thousand awks to answer a question the listing it had
# just done already knew. The counts are now tallied once, in the same pass
# that writes the candidates, and read into an array — after which asking is
# free, and asking inside `$( )` (which forks a subshell even for a builtin) is
# no longer how the callers ask.
declare -A READY_IN

load_ready_counts() {
  READY_IN=()
  local g n
  while IFS=$'\t' read -r g n; do READY_IN["$g"]="$n"; done <"$TMP/groups"
}

# The candidate set, rebuilt before every round because pod names change under
# it: one line per pod, tab separated, as
#   <key> <namespace> <pod> <node> <group> <ready>
# sorted by key. Written to $CAND rather than returned, because both the
# planner and the readiness check read it and neither wants to re-list.
# Why the last listing came out the size it did, filled in by list_candidates
# and read by why_empty. An empty candidate set has four quite different
# causes — the namespace is empty, everything in it was filtered out,
# everything in it is already terminating, or the API said no — and a chaos
# tool that cannot tell them apart is one you cannot debug.
LISTING_ERR=""

list_candidates() {
  local ns
  : >"$TMP/raw"
  : >"$TMP/tally"
  LISTING_ERR=""
  for ns in "${NAMESPACES[@]}"; do
    # stderr is kept rather than discarded. `kubectl get pods` on an empty
    # namespace exits 0 and says "No resources found" there, so this is not an
    # error path — but a token that expired, a namespace that was deleted and
    # an API server that is down all land here too, and used to be silently
    # indistinguishable from "nothing to kill".
    if ! kc get pods -n "$ns" ${SEL_ARGS[@]+"${SEL_ARGS[@]}"} \
      -o "custom-columns=$POD_COLUMNS" --no-headers >"$TMP/pods" 2>"$TMP/err"; then
      LISTING_ERR="${LISTING_ERR}${LISTING_ERR:+; }$ns: $(tr -d '\n' <"$TMP/err")"
      continue
    fi
    awk -v ns="$ns" -v inc="$INCLUDE" -v exc="$EXCLUDE" -v tally="$TMP/tally" '
        NF >= 7 {
          pod = $1; node = $2; kind = $3; owner = $4
          phase = $5; ready = $6; del = $7
          id = ns "/" pod
          total++
          if (inc != "" && id !~ inc) { filtered++; next }
          if (exc != "" && id ~ exc)  { filtered++; next }

          # A pod with a deletionTimestamp is already on its way out. Deleting
          # it again is a no-op that would be reported as a kill, and counting
          # it as a candidate inflates the plan with slots that are about to be
          # empty — which is what a run started moments after a `fixture-down`
          # or a rollout sees.
          if (del != "<none>")        { term++; next }
          kept++
          if (node == "<none>") node = "-"

          # The key names the slot, not the pod, so that "the same pod as last
          # cycle" survives the pod being replaced under a new name. What makes
          # a slot depends on who owns it: a DaemonSet has one pod per node, a
          # Deployment reaches its pods through a ReplicaSet whose name carries
          # a hash that changes on every rollout (stripped, so a rollout does
          # not reshuffle the plan), and a StatefulSet pod already has a stable
          # name of its own.
          if (kind == "DaemonSet")            key = "ds/" owner "@" node
          else if (kind == "StatefulSet")     key = "sts/" pod
          else if (kind == "ReplicaSet")      { sub(/-[0-9a-z]+$/, "", owner); key = "deploy/" owner "@" node }
          else if (kind == "Job")             key = "job/" owner "@" node
          else if (kind == "<none>")          { owner = pod; key = "pod/" pod }
          else                                key = tolower(kind) "/" owner "@" node

          # The group is the workload, which is the thing that recovers and the
          # thing MIN_READY counts. Deliberately not per node: a DaemonSet pod
          # coming back is the DaemonSet recovering.
          gkind = (kind == "<none>") ? "pod" : (kind == "ReplicaSet" ? "deploy" : tolower(kind))
          group = ns "/" gkind "/" owner

          # No deletionTimestamp check: a terminating pod is not a candidate
          # at all any more, so anything reaching here has none.
          is_ready = (ready == "True" && phase == "Running") ? 1 : 0
          print key "\t" ns "\t" pod "\t" node "\t" group "\t" is_ready
        }
        END { printf "%s\t%d\t%d\t%d\t%d\n", ns, total, filtered, term, kept >> tally }
      ' "$TMP/pods" >>"$TMP/raw"
  done

  # Two pods in one slot — two replicas of a Deployment on one node — would
  # otherwise share a key, and the plan could not say which of them it meant.
  # They are numbered in pod-name order, which is stable while both exist.
  # Only actual collisions are suffixed, so the common case keeps a key that
  # reads as what it is.
  LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k3,3 "$TMP/raw" |
    awk -F'\t' -v OFS='\t' '
      { line[NR] = $0; k[NR] = $1; n[$1]++ }
      END {
        for (i = 1; i <= NR; i++) {
          $0 = line[i]
          if (n[k[i]] > 1) $1 = $1 "#" (++seen[k[i]])
          print
        }
      }
    ' >"$CAND"

  awk -F'\t' '$6 == 1 { n[$5]++ } END { for (g in n) print g "\t" n[g] }' "$CAND" >"$TMP/groups"
  load_ready_counts
}

# Every tunable and its effective value, one per line, as
#   <name> <value> <set|default>
# The single source the log, config.env and the report all render from, so
# they cannot disagree about what the run was configured with.
config_lines() {
  local v val src
  for v in "${TUNABLES[@]}"; do
    # KUBECTL is an array, because it may carry flags. ${!v} on an array
    # yields element zero and nothing else, which recorded a KUBECTL of
    # `oc --context lab` as plain `oc` — a config dump that quietly disagreed
    # with the run it was describing.
    if [ "$v" = KUBECTL ]; then val="${KUBECTL[*]}"; else val="${!v}"; fi
    src="default"
    [ -n "${CONFIG_SET[$v]:-}" ] && src="set"
    printf '%s\t%s\t%s\n' "$v" "$val" "$src"
  done
}

# The same thing on one line, for the run-start event. Everything is quoted
# rather than only the values that need it, so the field can be parsed without
# knowing which those are. Built from config_lines so the two cannot drift.
config_oneline() {
  config_lines | awk -F'\t' '
    BEGIN { q = sprintf("%c", 39) }
    { v = $2; gsub(q, q "\\" q q, v); printf "%s%s=%s%s%s", (NR > 1 ? " " : ""), $1, q, v, q }
  '
}

# One sentence saying what the last listing actually saw, for the places that
# have to report an empty or surprising candidate set. Without it the only
# message available was "no candidate pods", which is the same words whether
# the filter was wrong, the namespace was empty, everything in it was already
# terminating, or kubectl never got an answer.
why_empty() {
  [ -n "$LISTING_ERR" ] && {
    printf 'kubectl could not list pods — %s' "$LISTING_ERR"
    return
  }
  awk -F'\t' '
    { total += $2; filtered += $3; term += $4; kept += $5 }
    END {
      if (total == 0)  { printf "no pods at all" }
      else if (kept)   { printf "%d of %d pods are candidates", kept, total }
      else {
        parts = ""
        if (term)     parts = term " already terminating"
        if (filtered) parts = parts (parts ? " and " : "") filtered " excluded by SELECTOR, INCLUDE or EXCLUDE"
        printf "none of the %d pods are candidates: %s", total, parts
      }
    }
  ' "$TMP/tally"
}

# The kill order for one cycle, one key per line. Deterministic mode is the
# sorted key order that list_candidates already produced. Random mode is a
# Fisher-Yates shuffle seeded with SEED + the cycle number: seeded so a run can
# be repeated, and varied per cycle so pods are not hit in a fixed rotation
# that a deterministic run would have covered anyway.
#
# The reproducibility is awk's: srand(n) fixes the stream for a given awk
# build, which the container pins and a host shell does not.
plan_for_cycle() { # <cycle>
  if [ "$MODE" = deterministic ]; then
    cut -f1 "$CAND"
  else
    cut -f1 "$CAND" | awk -v seed=$((SEED + $1)) '
      BEGIN { srand(seed) }
      { a[NR] = $0 }
      END {
        for (i = NR; i > 1; i--) { j = int(rand() * i) + 1; t = a[i]; a[i] = a[j]; a[j] = t }
        for (i = 1; i <= NR; i++) print a[i]
      }
    '
  fi
}

# Fields of the candidate line holding <key>, or nothing if the slot is empty —
# which happens when a pod has not been recreated yet, or moved to another
# node and so into another key.
resolve() { # <key>
  awk -F'\t' -v k="$1" '$1 == k { print; exit }' "$CAND"
}

# --------------------------------------------------------------------------
# The kill
# --------------------------------------------------------------------------

KILLS=0
SKIPS=0
FAILURES=0
ROUND=0

kill_key() { # <key>
  local key="$1" line ns pod node group avail iso0 ns0 iso1 ns1 out rc
  line="$(resolve "$key")"

  if [ -z "$line" ]; then
    # The slot is empty: the pod has not come back yet, or it came back on
    # another node and is now a different key. Worth a line in the timeline
    # rather than a silent nothing, because a plan that keeps skipping is the
    # cluster telling you something.
    now
    iso0="$NOW_ISO" ns0="$NOW_NS"
    event "$iso0" "$ns0" "$ROUND" skip "" "" "" "" "$key" "no pod holds this slot"
    info "skip $key — no pod holds this slot"
    SKIPS=$((SKIPS + 1))
    return 0
  fi

  # The key and the per-pod ready flag are re-read from the line and thrown
  # away: the key is what was looked up, and readiness is only ever asked about
  # a whole group.
  IFS=$'\t' read -r _ ns pod node group _ <<<"$line"
  avail="${READY_IN[$group]:-0}"

  if [ "$((avail - 1))" -lt "$MIN_READY" ]; then
    now
    iso0="$NOW_ISO" ns0="$NOW_NS"
    event "$iso0" "$ns0" "$ROUND" skip "$ns" "$pod" "$node" "$group" "$key" \
      "MIN_READY=$MIN_READY would be breached; ready=$avail"
    info "skip $ns/$pod — group has $avail ready, MIN_READY=$MIN_READY"
    SKIPS=$((SKIPS + 1))
    return 0
  fi

  # Two timestamps around the DELETE, because the call is not instant and the
  # thing being correlated against a benchmark graph is when the pod actually
  # went away — which is somewhere in between. The report shows the request
  # time and how long the call took, so the uncertainty is visible instead of
  # being hidden inside one number.
  now
  iso0="$NOW_ISO" ns0="$NOW_NS"
  event "$iso0" "$ns0" "$ROUND" kill-request "$ns" "$pod" "$node" "$group" "$key" \
    "$KILL_MODE; group ready=$avail"

  if [ "$DRY_RUN" -eq 1 ]; then
    out="dry run, nothing deleted"
    rc=0
  elif [ "$KILL_MODE" = force ]; then
    out="$(kc delete pod -n "$ns" "$pod" --grace-period=0 --force --wait=false 2>&1)"
    rc=$?
  else
    out="$(kc delete pod -n "$ns" "$pod" --grace-period="$GRACE" --wait=false 2>&1)"
    rc=$?
  fi
  now
  iso1="$NOW_ISO" ns1="$NOW_NS"

  if [ "$rc" -ne 0 ]; then
    event "$iso1" "$ns1" "$ROUND" kill-failed "$ns" "$pod" "$node" "$group" "$key" \
      "rc=$rc; $out"
    warn "delete failed for $ns/$pod: $out"
    FAILURES=$((FAILURES + 1))
    return 0
  fi

  event "$iso1" "$ns1" "$ROUND" kill-done "$ns" "$pod" "$node" "$group" "$key" \
    "call took $(elapsed_between "$ns0" "$ns1")s"
  KILLS=$((KILLS + 1))
  info "$([ "$DRY_RUN" -eq 1 ] && echo "would kill" || echo "killed") $ns/$pod on $node ($key) at $iso0"

  # Nothing was deleted, so nothing is going to drop and the recovery wait
  # would spend READY_TIMEOUT per round to report a disruption that never
  # happened. A dry run is meant to be quick and to show the plan.
  [ "$DRY_RUN" -eq 1 ] && return 0

  # One entry per group even when a batch kills several of its pods: the
  # baseline is the count from before the first of them, so the group is only
  # recovered once all of them are back.
  if ! grep -q "^$group	" "$TMP/wait" 2>/dev/null; then
    printf '%s\t%s\t%s\t0\n' "$group" "$avail" "$ns1" >>"$TMP/wait"
  fi
}

elapsed_between() { # <ns from> <ns to>
  local d=$((($2 - $1) / 1000000))
  printf '%d.%03d' $((d / 1000)) $((d % 1000))
}

# Blocks until every group the round touched is back to the ready count it had
# before, or until READY_TIMEOUT.
#
# Recovery is only accepted after the count has been seen to drop. Without
# that, a graceful kill — where the pod stays Ready for its grace period —
# would be declared recovered on the first poll, half a second after a delete
# that has not taken effect yet. A group that never drops is reported as
# `no-disruption`, which is a real result: the kill did not cost that component
# its readiness at all.
wait_for_recovery() {
  [ "$WAIT_READY" -eq 1 ] || return 0
  [ -s "$TMP/wait" ] || return 0

  local deadline nns iso g base kns dropped cur
  # A group with no ready pods at all has no row in the tally, hence the :-0 at
  # every read below: absent and zero are the same answer here.

  now
  nns="$NOW_NS"
  deadline=$((nns + READY_TIMEOUT * 1000000000))

  while :; do
    list_candidates
    now
    iso="$NOW_ISO" nns="$NOW_NS"
    : >"$TMP/wait.next"

    while IFS=$'\t' read -r g base kns dropped; do
      cur="${READY_IN[$g]:-0}"
      [ "$cur" -lt "$base" ] && dropped=1
      if [ "$dropped" -eq 1 ] && [ "$cur" -ge "$base" ]; then
        event "$iso" "$nns" "$ROUND" recovered "" "" "" "$g" "" \
          "ready=$cur/$base after $(elapsed_between "$kns" "$nns")s"
        info "recovered $g after $(elapsed_between "$kns" "$nns")s"
      else
        printf '%s\t%s\t%s\t%s\n' "$g" "$base" "$kns" "$dropped" >>"$TMP/wait.next"
      fi
    done <"$TMP/wait"
    mv "$TMP/wait.next" "$TMP/wait"

    [ -s "$TMP/wait" ] || break

    if [ "$nns" -ge "$deadline" ] || [ "$STOP" -eq 1 ]; then
      while IFS=$'\t' read -r g base kns dropped; do
        cur="${READY_IN[$g]:-0}"
        if [ "$dropped" -eq 0 ]; then
          event "$iso" "$nns" "$ROUND" no-disruption "" "" "" "$g" "" \
            "ready stayed at $cur/$base for $(elapsed_between "$kns" "$nns")s"
          info "no readiness drop in $g — the kill cost it nothing visible"
        else
          event "$iso" "$nns" "$ROUND" recovery-timeout "" "" "" "$g" "" \
            "ready=$cur/$base after $(elapsed_between "$kns" "$nns")s"
          warn "$g still at $cur/$base after $(elapsed_between "$kns" "$nns")s"
        fi
      done <"$TMP/wait"
      : >"$TMP/wait"
      break
    fi
    sleep "$POLL"
  done
}

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------

# One lane per group, time along the x axis in seconds since the run started —
# the same axis a benchmark run started at the same moment can be read on. A
# kill is a mark on its group's lane and a bar running from the kill to the
# moment the group was ready again, so a slow recovery is a long bar and the
# thing to look for in the benchmark's graph is whatever happens underneath it.
#
# Written by hand rather than by gnuplot: this is a handful of rectangles on a
# linear axis, and gnuplot is 20 MB of image and a data-file round trip to draw
# them.
# Kills paired with what became of them, one line per kill, as
#   <group> <kill t> <end t> <outcome> <pod>
# where t is elapsed seconds and outcome is one of recovered, timeout, nodrop
# or open (the run ended while the group was still down).
#
# All three charts need this same pairing, and the timeline used to do it
# inline. Doing it once means the heatmap and the scatter cannot disagree with
# the timeline about when a component was down — which, since the whole point
# is reading them against each other, would be worse than any of them being
# wrong on its own.
pair_kills() { # <events.csv> <span seconds>
  awk -F, -v span="$2" '
    NR == 1 { next }
    {
      t = $3 + 0; ev = $5; group = $9
      if (ev == "kill-request") { pend[group] = t; podof[group] = $7 }
      else if (ev == "kill-done") { n++; kt[n] = pend[group]; kg[n] = group; kp[n] = podof[group]; open[group] = n }
      else if (ev == "recovered" || ev == "recovery-timeout" || ev == "no-disruption") {
        if (group in open) {
          i = open[group]; rt[i] = t
          rk[i] = (ev == "recovered" ? "recovered" : (ev == "no-disruption" ? "nodrop" : "timeout"))
          delete open[group]
        }
      }
    }
    END {
      for (i = 1; i <= n; i++)
        printf "%s\t%.3f\t%.3f\t%s\t%s\n", kg[i], kt[i],
          (i in rt ? rt[i] : span), (i in rk ? rk[i] : "open"), kp[i]
    }
  ' "$1"
}

# --------------------------------------------------------------------------
# The charts
#
# Hand-written SVG rather than gnuplot, for the reason runtime-deps.nix gives:
# these are rectangles and circles on linear axes, and gnuplot is 20 MB of
# image and a data-file round trip to draw them.
#
# Colours come from one validated palette and mean the same thing in all three:
#   #2a78d6  the data — a recovery, a bar, a filled cell
#   #d03b3b  a kill, and anything that never came back
#   #52514e  ink, and the absence of a measurement
# The blue/red pair was checked for colour-vision separation rather than
# eyeballed; an earlier green-for-good against that red came out at deltaE 4.1
# under deuteranopia, which is to say indistinguishable, so nothing here is
# green and every status also carries a shape and a label.
# --------------------------------------------------------------------------

# A tick step of 1, 2 or 5 x 10^n giving roughly the requested number of ticks.
# Shared by all three charts as an awk function, textually, because awk has no
# way to include one.
AWK_NICE='
  function nice_step(range, want,   raw, mag, r) {
    raw = range / want
    if (raw <= 0) return 1
    mag = 1
    # Down as well as up. Without the first loop this floors at 1, so a
    # distribution that lives between 0 and 2 seconds got two bins and a y
    # axis with one tick on it.
    while (mag > raw) mag /= 10
    while (mag * 10 <= raw) mag *= 10
    r = raw / mag
    return (r <= 1 ? 1 : (r <= 2 ? 2 : (r <= 5 ? 5 : 10))) * mag
  }
  # Decimals appropriate to a step: 0.1 wants one, 5 wants none.
  function fmt(v, step) {
    return (step >= 1 ? sprintf("%d", v + 0.0001) :
           (step >= 0.1 ? sprintf("%.1f", v) : sprintf("%.2f", v)))
  }
  function hms(t) { return (t >= 90 ? sprintf("%dm", int(t / 60)) : sprintf("%ds", int(t))) }
  function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
'

# One lane per component, time along the x axis — a mark where each kill
# landed and a bar running to the moment the component was ready again.
#
# The most direct view there is, and the first to fail: at a hundred kills the
# marks merge into a picket fence and each bar is a couple of pixels. That is
# what the heatmap is for. This one is still drawn, because for the runs where
# it is legible nothing else shows the individual events as plainly.
timeline_svg() { # <pairs> <span seconds>
  awk -F'\t' -v span="$2" "$AWK_NICE"'
    { n++; g[n] = $1; kt[n] = $2 + 0; et[n] = $3 + 0; ok[n] = $4; pod[n] = $5
      if (!($1 in lane)) { lane[$1] = ++lanes; name[lanes] = $1 }
      if (et[n] > tmax) tmax = et[n] }
    END {
      if (span > tmax) tmax = span
      if (tmax <= 0) tmax = 1
      if (lanes == 0) { print "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"></svg>"; exit }

      # Lanes in name order, so two runs against the same cluster put the same
      # component on the same row. Sorted by hand because asorti() is a gawk
      # extension and this is otherwise plain awk.
      for (i = 2; i <= lanes; i++) {
        v = name[i]
        for (j = i - 1; j >= 1 && name[j] > v; j--) name[j + 1] = name[j]
        name[j + 1] = v
      }
      for (i = 1; i <= lanes; i++) lane[name[i]] = i

      W = 1120; L = 300; R = 24; TOPM = 34; ROWH = 34; BOT = 46
      H = TOPM + lanes * ROWH + BOT
      plot = W - L - R

      printf "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 %d %d\" width=\"100%%\" font-family=\"system-ui, sans-serif\" font-size=\"12\">\n", W, H
      printf "<rect width=\"%d\" height=\"%d\" fill=\"#fcfcfb\"/>\n", W, H

      step = nice_step(tmax, 8)
      for (t = 0; t <= tmax; t += step) {
        x = L + plot * t / tmax
        printf "<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%d\" stroke=\"#e6e5e2\"/>\n", x, TOPM - 8, x, TOPM + lanes * ROWH
        printf "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\" fill=\"#52514e\">%s</text>\n", x, TOPM + lanes * ROWH + 18, hms(t)
      }
      printf "<text x=\"%d\" y=\"%d\" text-anchor=\"middle\" fill=\"#52514e\">seconds since the run started</text>\n", L + plot / 2, H - 10

      for (i = 1; i <= lanes; i++) {
        y = TOPM + (i - 0.5) * ROWH
        printf "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"#f2f1ee\" stroke-width=\"18\"/>\n", L, y, W - R, y
        lbl = name[i]
        if (length(lbl) > 44) lbl = "..." substr(lbl, length(lbl) - 40)
        printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" fill=\"#0b0b0b\">%s</text>\n", L - 10, y + 4, esc(lbl)
      }

      for (i = 1; i <= n; i++) {
        y = TOPM + (lane[g[i]] - 0.5) * ROWH
        x1 = L + plot * kt[i] / tmax
        x2 = L + plot * et[i] / tmax
        if (x2 < x1 + 2) x2 = x1 + 2
        fill = (ok[i] == "recovered" ? "#2a78d6" : (ok[i] == "nodrop" ? "#9a9892" : "#d03b3b"))
        printf "<rect x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"18\" fill=\"%s\" fill-opacity=\"0.5\"><title>%s</title></rect>\n", x1, y - 9, x2 - x1, fill, esc(pod[i] " " ok[i] " after " sprintf("%.1f", et[i] - kt[i]) "s")
        printf "<rect x=\"%.1f\" y=\"%.1f\" width=\"2.5\" height=\"26\" fill=\"#d03b3b\"><title>%s</title></rect>\n", x1 - 1.2, y - 13, esc(pod[i] " killed at +" kt[i] "s")
      }

      lx = L
      printf "<rect x=\"%d\" y=\"8\" width=\"3\" height=\"12\" fill=\"#d03b3b\"/><text x=\"%d\" y=\"18\" fill=\"#52514e\">kill</text>\n", lx, lx + 8
      printf "<rect x=\"%d\" y=\"8\" width=\"14\" height=\"12\" fill=\"#2a78d6\" fill-opacity=\"0.5\"/><text x=\"%d\" y=\"18\" fill=\"#52514e\">until ready again</text>\n", lx + 46, lx + 64
      printf "<rect x=\"%d\" y=\"8\" width=\"14\" height=\"12\" fill=\"#d03b3b\" fill-opacity=\"0.5\"/><text x=\"%d\" y=\"18\" fill=\"#52514e\">never came back</text>\n", lx + 190, lx + 208
      printf "<rect x=\"%d\" y=\"8\" width=\"14\" height=\"12\" fill=\"#9a9892\" fill-opacity=\"0.5\"/><text x=\"%d\" y=\"18\" fill=\"#52514e\">no readiness drop</text>\n", lx + 330, lx + 348
      print "</svg>"
    }
  ' "$1"
}

# The same data as the timeline, binned: component down the side, time across,
# each cell shaded by how much of that slice of the run the component spent
# below its ready count.
#
# This is the one that survives a long run. The grid is a fixed size whatever
# ITERATIONS is — a hundred kills and ten kills produce the same shape, and the
# question it answers, "which component was down and roughly when", is the one
# a dense timeline stops being able to answer.
#
# Zero is left as the surface rather than given the palest step, so the eye
# reads the run as marks on an empty grid instead of a wall of pale blue.
heatmap_svg() { # <pairs> <span seconds>
  awk -F'\t' -v span="$2" "$AWK_NICE"'
    { n++; g[n] = $1; kt[n] = $2 + 0; et[n] = $3 + 0
      if (!($1 in lane)) { lane[$1] = ++lanes; name[lanes] = $1 }
      if (et[n] > tmax) tmax = et[n] }
    END {
      if (span > tmax) tmax = span
      if (tmax <= 0) tmax = 1
      if (lanes == 0) { print "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"></svg>"; exit }

      for (i = 2; i <= lanes; i++) {
        v = name[i]
        for (j = i - 1; j >= 1 && name[j] > v; j--) name[j + 1] = name[j]
        name[j + 1] = v
      }
      for (i = 1; i <= lanes; i++) lane[name[i]] = i

      W = 1120; L = 300; R = 24; TOPM = 46; ROWH = 26; BOT = 62
      BINS = 60
      H = TOPM + lanes * ROWH + BOT
      plot = W - L - R
      binw = plot / BINS
      bindur = tmax / BINS

      # Seconds of overlap between each down-interval and each bin. An interval
      # shorter than a bin still marks its bin, which is the point: a 20s
      # recovery inside a 100s bin is a fifth of a cell, not nothing.
      for (i = 1; i <= n; i++) {
        b0 = int(kt[i] / bindur); b1 = int(et[i] / bindur)
        if (b1 >= BINS) b1 = BINS - 1
        for (b = b0; b <= b1; b++) {
          lo = b * bindur; hi = lo + bindur
          a = (kt[i] > lo ? kt[i] : lo); z = (et[i] < hi ? et[i] : hi)
          if (z > a) { cell[lane[g[i]] SUBSEP b] += z - a; if (cell[lane[g[i]] SUBSEP b] > vmax) vmax = cell[lane[g[i]] SUBSEP b] }
        }
      }
      if (vmax <= 0) vmax = 1

      split("#86b6ef #5598e7 #2a78d6 #1c5cab #104281", ramp, " ")

      printf "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 %d %d\" width=\"100%%\" font-family=\"system-ui, sans-serif\" font-size=\"12\">\n", W, H
      printf "<rect width=\"%d\" height=\"%d\" fill=\"#fcfcfb\"/>\n", W, H

      for (i = 1; i <= lanes; i++) {
        y = TOPM + (i - 1) * ROWH
        lbl = name[i]
        if (length(lbl) > 44) lbl = "..." substr(lbl, length(lbl) - 40)
        printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" fill=\"#0b0b0b\">%s</text>\n", L - 10, y + ROWH / 2 + 4, esc(lbl)
        for (b = 0; b < BINS; b++) {
          x = L + b * binw
          v = cell[i SUBSEP b] + 0
          if (v <= 0) {
            printf "<rect x=\"%.2f\" y=\"%.1f\" width=\"%.2f\" height=\"%d\" fill=\"none\" stroke=\"#eeede9\"/>\n", x, y + 1, binw, ROWH - 3
          } else {
            k = int(5 * v / vmax) + 1; if (k > 5) k = 5
            printf "<rect x=\"%.2f\" y=\"%.1f\" width=\"%.2f\" height=\"%d\" fill=\"%s\"><title>%s</title></rect>\n", x, y + 1, binw, ROWH - 3, ramp[k], esc(sprintf("%s down %.0fs of the %.0fs from +%.0fs", name[i], v, bindur, b * bindur))
          }
        }
      }

      step = nice_step(tmax, 8)
      ybase = TOPM + lanes * ROWH
      for (t = 0; t <= tmax; t += step) {
        x = L + plot * t / tmax
        printf "<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#cfcec9\"/>\n", x, ybase, x, ybase + 5
        printf "<text x=\"%.1f\" y=\"%.1f\" text-anchor=\"middle\" fill=\"#52514e\">%s</text>\n", x, ybase + 19, hms(t)
      }
      printf "<text x=\"%d\" y=\"%d\" text-anchor=\"middle\" fill=\"#52514e\">seconds since the run started</text>\n", L + plot / 2, H - 24

      printf "<text x=\"%d\" y=\"20\" fill=\"#52514e\">seconds down per %.0fs slice:</text>\n", L, bindur
      for (k = 1; k <= 5; k++)
        printf "<rect x=\"%d\" y=\"9\" width=\"22\" height=\"13\" fill=\"%s\"/>\n", L + 178 + (k - 1) * 23, ramp[k]
      printf "<text x=\"%d\" y=\"20\" fill=\"#52514e\">0</text>\n", L + 170
      printf "<text x=\"%d\" y=\"20\" fill=\"#52514e\">%.0f</text>\n", L + 178 + 5 * 23 + 4, vmax
      print "</svg>"
    }
  ' "$1"
}

# How long each kill took to come back, against when in the run it happened.
#
# The question a long soak is actually asking — does the cluster get slower to
# recover the more you hit it — which neither the timeline nor the heatmap can
# answer, because both spend their y axis on identity. Here y is the duration
# and every kill is one mark, so a hundred of them is a hundred readable points
# rather than a hundred overlapping bars.
#
# Kills that never recovered are drawn as open marks pinned to the top of the
# plot: their duration is not known, only that it exceeded READY_TIMEOUT.
# Dropping them would take the worst outcomes out of a chart about how bad
# things got.
recovery_svg() { # <pairs> <span seconds>
  awk -F'\t' -v span="$2" "$AWK_NICE"'
    {
      n++; kt[n] = $2 + 0; dur[n] = $3 - $2; ok[n] = $4; pod[n] = $5; grp[n] = $1
      if (kt[n] > tmax) tmax = kt[n]
      if (ok[n] == "recovered") { if (dur[n] > dmax) dmax = dur[n]; m++; med[m] = dur[n] }
    }
    END {
      if (span > tmax) tmax = span
      if (tmax <= 0) tmax = 1
      if (n == 0) { print "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"></svg>"; exit }
      if (dmax <= 0) dmax = 1
      dmax *= 1.15

      W = 1120; L = 74; R = 24; TOPM = 34; PH = 300; BOT = 58
      H = TOPM + PH + BOT
      plot = W - L - R

      # A marker sitting exactly on tmax would be drawn half outside the plot,
      # and the last kill of a run always does. Pad the domain by one marker
      # width rather than by a percentage, so the gap is the same on a
      # three-minute run and a three-hour one.
      tmax += 10 * tmax / plot

      printf "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 %d %d\" width=\"100%%\" font-family=\"system-ui, sans-serif\" font-size=\"12\">\n", W, H
      printf "<rect width=\"%d\" height=\"%d\" fill=\"#fcfcfb\"/>\n", W, H

      ystep = nice_step(dmax, 5)
      for (v = 0; v <= dmax; v += ystep) {
        y = TOPM + PH - PH * v / dmax
        printf "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"#e6e5e2\"/>\n", L, y, W - R, y
        printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" fill=\"#52514e\">%gs</text>\n", L - 8, y + 4, v
      }
      xstep = nice_step(tmax, 8)
      for (t = 0; t <= tmax; t += xstep) {
        x = L + plot * t / tmax
        printf "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\" fill=\"#52514e\">%s</text>\n", x, TOPM + PH + 18, hms(t)
      }
      printf "<text x=\"%d\" y=\"%d\" text-anchor=\"middle\" fill=\"#52514e\">seconds since the run started</text>\n", L + plot / 2, H - 22
      printf "<text x=\"14\" y=\"%d\" text-anchor=\"middle\" fill=\"#52514e\" transform=\"rotate(-90 14 %d)\">time to recover</text>\n", TOPM + PH / 2, TOPM + PH / 2

      # Median of the recovered kills, as a reference the eye can read drift
      # against. Insertion sort: the counts here are hundreds, not millions.
      if (m > 0) {
        for (i = 2; i <= m; i++) { v = med[i]; for (j = i - 1; j >= 1 && med[j] > v; j--) med[j + 1] = med[j]; med[j + 1] = v }
        mid = (m % 2 ? med[int(m / 2) + 1] : (med[m / 2] + med[m / 2 + 1]) / 2)
        y = TOPM + PH - PH * mid / dmax
        printf "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"#52514e\" stroke-width=\"1.5\" stroke-dasharray=\"6 4\"/>\n", L, y, W - R, y
        printf "<text x=\"%d\" y=\"%.1f\" fill=\"#52514e\">median %.1fs</text>\n", W - R - 92, y - 6, mid
      }

      for (i = 1; i <= n; i++) {
        x = L + plot * kt[i] / tmax
        if (ok[i] == "recovered") {
          y = TOPM + PH - PH * dur[i] / dmax
          printf "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"4.5\" fill=\"#2a78d6\" fill-opacity=\"0.75\" stroke=\"#fcfcfb\" stroke-width=\"1.5\"><title>%s</title></circle>\n", x, y, esc(sprintf("%s recovered in %.1fs at +%.0fs", pod[i], dur[i], kt[i]))
        } else if (ok[i] == "nodrop") {
          printf "<circle cx=\"%.1f\" cy=\"%d\" r=\"4\" fill=\"none\" stroke=\"#9a9892\" stroke-width=\"1.5\"><title>%s</title></circle>\n", x, TOPM + PH, esc(pod[i] " — no readiness drop")
        } else {
          printf "<path d=\"M %.1f %d l 6 10 l -12 0 z\" fill=\"none\" stroke=\"#d03b3b\" stroke-width=\"2\"><title>%s</title></path>\n", x, TOPM + 4, esc(sprintf("%s never came back (still down after %.0fs)", pod[i], dur[i]))
        }
      }

      printf "<circle cx=\"%d\" cy=\"14\" r=\"4.5\" fill=\"#2a78d6\" fill-opacity=\"0.75\"/><text x=\"%d\" y=\"18\" fill=\"#52514e\">recovered</text>\n", L + 6, L + 16
      printf "<path d=\"M %d 9 l 5 9 l -10 0 z\" fill=\"none\" stroke=\"#d03b3b\" stroke-width=\"2\"/><text x=\"%d\" y=\"18\" fill=\"#52514e\">never came back (at the ceiling)</text>\n", L + 106, L + 118
      printf "<circle cx=\"%d\" cy=\"14\" r=\"4\" fill=\"none\" stroke=\"#9a9892\" stroke-width=\"1.5\"/><text x=\"%d\" y=\"18\" fill=\"#52514e\">no readiness drop (on the floor)</text>\n", L + 330, L + 342
      print "</svg>"
    }
  ' "$1"
}

# How long recoveries take, as a distribution rather than a sequence: one small
# histogram per component, plus one for all of them together, on a shared x
# axis so the facets can be read against each other.
#
# Small multiples rather than one chart with a colour per component, because
# colour-as-identity stops being reliable past three series and a chaos run can
# easily touch five. Each facet is labelled instead, so nothing depends on
# telling two blues apart.
#
# The y axis is per facet, not shared: the "all components" row holds every
# sample and would flatten each component's row into nothing. Each facet
# therefore prints its own n and peak, and what is comparable across rows is
# the *shape* and where the mass sits — which is the question a histogram is
# being asked.
#
# Only recoveries are binned. A kill that never came back has no duration to
# bin, and one that cost the component no readiness at all was never down —
# both are counted in the facet's label instead of being quietly folded into
# the first bucket, which would put a spike at zero that no pod ever earned.
histogram_svg() { # <pairs>
  awk -F'\t' "$AWK_NICE"'
    {
      g = $1; dur = $3 - $2; ok = $4
      if (!(g in idx)) { idx[g] = ++ng; name[ng] = g }
      if (ok == "recovered") {
        n++; d[n] = dur; gi[n] = idx[g]
        if (dur > dmax) dmax = dur
      }
      else if (ok == "nodrop") { nd[idx[g]]++; ndall++ }
      else                     { to[idx[g]]++; toall++ }
    }
    END {
      if (n == 0) { print "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"></svg>"; exit }

      for (i = 2; i <= ng; i++) {
        v = name[i]
        for (j = i - 1; j >= 1 && name[j] > v; j--) name[j + 1] = name[j]
        name[j + 1] = v
      }
      for (i = 1; i <= ng; i++) rank[name[i]] = i
      # idx was assigned in first-seen order; remap the per-sample group index
      # onto the sorted order so the rows match the other charts.
      for (g in idx) remap[idx[g]] = rank[g]

      if (dmax <= 0) dmax = 1
      # Asked high on purpose: nice_step rounds up to the next 1/2/5, so
      # asking for 18 over a 40-second range returns 5s bins and delivers 8.
      # Asking for 30 returns 2s bins and delivers 20.
      binw = nice_step(dmax, 30)
      nbins = int(dmax / binw) + 1
      xmax = nbins * binw

      for (i = 1; i <= n; i++) {
        b = int(d[i] / binw)
        h[0, b]++; h[remap[gi[i]], b]++
        cnt[0]++; cnt[remap[gi[i]]]++
        s0 = ++m[0];  all[0, s0] = d[i]
        r0 = remap[gi[i]]; s1 = ++m[r0]; all[r0, s1] = d[i]
      }
      for (g in idx) { toS[rank[g]] = to[idx[g]] + 0; ndS[rank[g]] = nd[idx[g]] + 0 }

      W = 1120; L = 300; R = 24; TOPM = 30; FH = 62; BH = 40; BOT = 52
      rows = ng + 1
      H = TOPM + rows * FH + BOT
      plot = W - L - R
      binpx = plot / nbins

      printf "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 %d %d\" width=\"100%%\" font-family=\"system-ui, sans-serif\" font-size=\"12\">\n", W, H
      printf "<rect width=\"%d\" height=\"%d\" fill=\"#fcfcfb\"/>\n", W, H

      for (f = 0; f < rows; f++) {
        top = TOPM + f * FH
        base = top + BH
        peak = 0
        for (b = 0; b < nbins; b++) if (h[f, b] > peak) peak = h[f, b]
        if (peak <= 0) peak = 1

        lbl = (f == 0 ? "all components" : name[f])
        if (length(lbl) > 42) lbl = "..." substr(lbl, length(lbl) - 38)
        printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" fill=\"#0b0b0b\">%s</text>\n", L - 10, top + 16, esc(lbl)

        k = m[f]
        for (i = 2; i <= k; i++) { v = all[f, i]; for (j = i - 1; j >= 1 && all[f, j] > v; j--) all[f, j + 1] = all[f, j]; all[f, j + 1] = v }
        mid = (k % 2 ? all[f, int(k / 2) + 1] : (all[f, k / 2] + all[f, k / 2 + 1]) / 2)

        # The gutter holds the name and a short note; the peak goes inside the
        # plot, because the y axis is per facet and the number is what makes it
        # readable. Everything else was overflowing the label column off the
        # left edge of the picture.
        nto = (f == 0 ? toall : toS[f]) + 0
        nnd = (f == 0 ? ndall : ndS[f]) + 0
        note = sprintf("n=%d · median %ss", cnt[f] + 0, fmt(mid, binw < 0.1 ? binw : 0.1))
        if (nto > 0) note = note sprintf(" · %d timed out", nto)
        if (nnd > 0) note = note sprintf(" · %d no drop", nnd)
        printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" fill=\"#52514e\" font-size=\"11\">%s</text>\n", L - 10, top + 32, esc(note)
        printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" fill=\"#9a9892\" font-size=\"11\">peak %d</text>\n", W - R, top + 11, peak

        printf "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"#cfcec9\"/>\n", L, base, W - R, base

        for (b = 0; b < nbins; b++) {
          c = h[f, b] + 0
          if (c <= 0) continue
          bh = BH * c / peak
          if (bh < 2) bh = 2
          printf "<rect x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" rx=\"2\" fill=\"#2a78d6\"><title>%s</title></rect>\n", \
            L + b * binpx + 0.75, base - bh, (binpx - 1.5 > 1 ? binpx - 1.5 : 1), bh, \
            esc(sprintf("%d of %d between %ss and %ss", c, cnt[f], fmt(b * binw, binw), fmt((b + 1) * binw, binw)))
        }

        x = L + plot * mid / xmax
        printf "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#52514e\" stroke-width=\"1.5\" stroke-dasharray=\"4 3\"><title>median %ss</title></line>\n", x, top - 2, x, base + 4, fmt(mid, 0.01)
      }

      ybase = TOPM + rows * FH - FH + BH
      step = nice_step(xmax, 8)
      for (t = 0; t <= xmax + step / 2; t += step) {
        if (t > xmax) break
        x = L + plot * t / xmax
        printf "<text x=\"%.1f\" y=\"%.1f\" text-anchor=\"middle\" fill=\"#52514e\">%ss</text>\n", x, ybase + 20, fmt(t, step)
      }
      printf "<text x=\"%d\" y=\"%d\" text-anchor=\"middle\" fill=\"#52514e\">time to recover — bars are %ss wide, dashed line is the median</text>\n", L + plot / 2, H - 14, fmt(binw, binw)
      print "</svg>"
    }
  ' "$1"
}

# The Markdown half of the report. Everything in it comes out of events.csv, so
# a run that was interrupted still reports what it managed to do.
report_md() { # <events.csv> <end iso> <span seconds>
  cat <<MDEOF
# Storage chaos run

| setting | value |
|---|---|
| Started | \`$START_ISO\` (epoch ns \`$START_NS\`) |
| Ended | \`$2\` |
| Duration | ${3}s |
| Namespaces | \`${NAMESPACES[*]}\` |
| Mode | \`$MODE\`$([ "$MODE" = random ] && echo ", seed \`$SEED\`") |
| Kill mode | \`$KILL_MODE\`$([ "$KILL_MODE" = graceful ] && echo ", grace ${GRACE}s") |
| Rounds run | $ROUND of $([ "$ITERATIONS" -eq 0 ] && echo "unlimited" || echo "$ITERATIONS"), $BATCH pod(s) each |
| Wait for recovery | $([ "$WAIT_READY" -eq 1 ] && echo "yes, up to ${READY_TIMEOUT}s, polled every ${POLL}s" || echo "no") |
| Dry run | $([ "$DRY_RUN" -eq 1 ] && echo "yes — nothing was deleted" || echo "no") |
| Killed / skipped / failed | $KILLS / $SKIPS / $FAILURES |
| Output | \`$OUTDIR\` |

## Configuration

Every tunable and the value this run used. **set** means it came from the
environment; **default** means the script chose it, and a future version is
free to choose differently — which is the distinction that makes an old report
still readable. The same list is in \`config.env\` beside this file, in a form
that can be fed straight back in.

MDEOF

  printf '| variable | value | source |\n|---|---|---|\n'
  config_lines | awk -F'\t' '{ printf "| `%s` | %s | %s |\n", $1, ($2 == "" ? "_(empty)_" : "`" $2 "`"), $3 }'
  printf '| `NAMESPACES` | `%s` | argument |\n\n' "${NAMESPACES[*]}"

  cat <<MDEOF
## Reading this against a benchmark

Every time below is UTC, and \`+s\` is seconds since this run started. A
benchmark started at the same time has its own clock on the same axis: line the
two up on \`$START_ISO\` and a kill mark should sit at the front of whatever the
benchmark's throughput graph does next.

Two things bound the numbers. A kill is recorded twice — when the delete was
requested and when the API call returned — and the pod stopped serving
somewhere in between; the table shows the request time and the call's duration.
A recovery is only ever seen at the next poll, so every recovery time is
accurate to ${POLL}s and biased late by up to that much.

\`events.csv\` beside this file has all of it to microsecond resolution,
including the events this report summarises away. Its \`epoch_ns\` column is in
nanoseconds and its last three digits are always zero: the clock is read
without forking a process, which costs a thousandfold in resolution and buys
back about a hundredfold in how close the timestamp sits to the event it
marks.

## Charts

Four views of the same kills, because no single one survives every run length.

### Which component was down, and roughly when

![Heatmap of time spent degraded, per component per time slice](heatmap.svg)

A fixed grid whatever \`ITERATIONS\` was: component down the side, the run
across, each cell shaded by how much of that slice it spent below its ready
count. This is the one to hold against a benchmark graph on a long run — ten
kills and a hundred kills produce the same shape.

### Did recovery get worse as the run went on

![Time to recover for each kill, against when it happened](recovery.svg)

One mark per kill, y is how long it took to come back. Kills that never
recovered are open triangles pinned to the top: their duration is not known,
only that it passed \`READY_TIMEOUT\`, and leaving them out would take the worst
outcomes out of a chart about how bad things got.

### How long recoveries take

![Distribution of recovery times, overall and per component](histogram.svg)

The same recoveries as a distribution instead of a sequence: one facet per
component over a shared x axis, so a component that is reliably slow looks
different from one that is usually fast and occasionally terrible — a
difference the median in the table above cannot show.

The y axis is per facet rather than shared, because the "all components" row
holds every sample and would flatten the rest to nothing; each row prints its
own count and peak. Only recoveries are binned. Kills that never came back have
no duration to bin and kills that cost the component no readiness were never
down, so both are counted in the row's label rather than folded into the first
bucket.

### Every kill individually

![Timeline of kills and recoveries](timeline.svg)
$TIMELINE_NOTE
## Kills

MDEOF

  awk -F, '
    NR == 1 { next }
    $5 == "kill-request" { pend[$9] = $3; iso[$9] = $1; pod[$9] = $6 "/" $7; node[$9] = $8; key[$9] = $10 }
    $5 == "kill-done" {
      n++; T[n] = pend[$9]; I[n] = iso[$9]; P[n] = pod[$9]; N[n] = node[$9]
      C[n] = $11; sub(/^call took /, "", C[n]); sub(/s$/, "", C[n])
      G[n] = $9; K[n] = key[$9]; open[$9] = n
    }
    $5 == "kill-failed" { n++; T[n] = pend[$9]; I[n] = iso[$9]; P[n] = pod[$9]; N[n] = node[$9]; G[n] = $9; K[n] = key[$9]; C[n] = "-"; R[n] = "**delete failed**" }
    $5 == "recovered" || $5 == "recovery-timeout" || $5 == "no-disruption" {
      if ($9 in open) {
        d = $11; sub(/^.*after /, "", d); sub(/s$/, "", d)
        R[open[$9]] = ($5 == "recovered" ? d "s" : ($5 == "no-disruption" ? "no drop" : "**timeout** (" d "s)"))
        delete open[$9]
      }
    }
    END {
      if (n == 0) { print "No pod was killed."; print ""; exit }
      print "| # | +s | UTC | pod | node | group | delete call | back ready after |"
      print "|---:|---:|---|---|---|---|---:|---:|"
      for (i = 1; i <= n; i++)
        printf "| %d | %s | %s | `%s` | `%s` | `%s` | %s | %s |\n",
          i, T[i], I[i], P[i], N[i], G[i], (C[i] == "-" ? "-" : C[i] "s"), (i in R ? R[i] : "-")
      print ""
    }
  ' "$1"

  printf '## Per component\n\n'
  awk -F, '
    NR == 1 { next }
    $5 == "kill-done"       { k[$9]++; seen[$9] = 1 }
    $5 == "kill-failed"     { f[$9]++; seen[$9] = 1 }
    $5 == "skip" && $9 != "" { s[$9]++; seen[$9] = 1 }
    $5 == "recovered" {
      d = $11; sub(/^.*after /, "", d); sub(/s$/, "", d); d += 0
      r[$9]++; sum[$9] += d
      if (!(($9) in mn) || d < mn[$9]) mn[$9] = d
      if (d > mx[$9]) mx[$9] = d
      seen[$9] = 1
    }
    $5 == "recovery-timeout" { t[$9]++; seen[$9] = 1 }
    $5 == "no-disruption"    { nd[$9]++; seen[$9] = 1 }
    END {
      print "| group | killed | skipped | failed | recovered | mean | min | max | timed out | no drop |"
      print "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
      for (g in seen)
        printf "| `%s` | %d | %d | %d | %d | %s | %s | %s | %d | %d |\n",
          g, k[g] + 0, s[g] + 0, f[g] + 0, r[g] + 0,
          (r[g] ? sprintf("%.1fs", sum[g] / r[g]) : "-"),
          (r[g] ? sprintf("%.1fs", mn[g]) : "-"),
          (r[g] ? sprintf("%.1fs", mx[g]) : "-"), t[g] + 0, nd[g] + 0
    }
  ' "$1" | { read -r h1; read -r h2; printf '%s\n%s\n' "$h1" "$h2"; sort; }

  printf '\n## Kill order\n\n```\n'
  sed -n '/^kill order/,$p' "$PLANFILE" 2>/dev/null | tail -n +2
  printf '```\n'
}

render_html() { # <markdown> <html out> <svg directory>
  {
    cat <<'HEADEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Storage Chaos Report</title>
<style>
:root {
  color-scheme: light dark;
  --bg: #fff; --fg: #1c1e21; --muted: #62676c; --rule: #dcdfe3;
  --accent: #1a6ec4; --code-bg: #f4f5f7; --head-bg: #eef1f4;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #16181c; --fg: #d5d9de; --muted: #979ca3; --rule: #2f333a;
    --accent: #6cb0f0; --code-bg: #1e2126; --head-bg: #22262c;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0 auto; max-width: 68rem; padding: 2.5rem 2rem 6rem;
  background: var(--bg); color: var(--fg);
  font: 16px/1.6 system-ui, -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
}
code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
h1 { font-size: 2rem; margin: 0 0 1.5rem; }
h2 { font-size: 1.5rem; margin: 2.5rem 0 1rem; padding-bottom: 0.3rem;
     border-bottom: 1px solid var(--rule); }
a { color: var(--accent); }
p, ul, ol { margin: 0 0 1rem; }
.tablewrap { overflow-x: auto; margin: 0 0 1.25rem; }
table { border-collapse: collapse; font-size: 0.9rem; }
th, td { border: 1px solid var(--rule); padding: 0.35rem 0.7rem; text-align: left;
         white-space: nowrap; }
thead th { background: var(--head-bg); font-weight: 600; }
tbody tr:nth-child(even) { background: var(--code-bg); }
pre { background: var(--code-bg); border: 1px solid var(--rule); border-radius: 4px;
      padding: 0.75rem 1rem; overflow-x: auto; font-size: 0.85rem; margin: 0 0 1.25rem; }
pre code { background: none; padding: 0; }
code { background: var(--code-bg); border-radius: 3px; padding: 0.1em 0.2em;
       font-size: 0.875em; }
/* The timeline keeps its own white ground in both themes: the lanes and the
   bars are picked against white, and inverting the page under them would leave
   the ticks unreadable. */
.chart { background: #fcfcfb; border: 1px solid var(--rule); border-radius: 4px;
         padding: 0.5rem; overflow-x: auto; margin: 0 0 1.5rem; }
.chart svg { display: block; min-width: 46rem; }
h3 { font-size: 1.1rem; margin: 1.75rem 0 0.6rem; }
</style>
</head>
<body>
HEADEOF
    # cmark-gfm leaves tables unwrapped and would leave the timeline as a
    # broken <img> in a file that is meant to travel on its own, so the image
    # reference is swapped for the SVG itself and every table gets the
    # horizontal scroll container it needs on a narrow screen.
    cmark-gfm --unsafe -e table -e autolink "$1" |
      awk -v svgdir="$3" '
        # Every chart is inlined rather than left as an <img>, so the report
        # is one file that can be mailed around. The name comes out of the
        # tag, so adding a chart to the Markdown needs no change here.
        match($0, /<img src="[a-z]+\.svg"/) {
          f = substr($0, RSTART + 10, RLENGTH - 11)
          print "<figure class=\"chart\">"
          while ((getline line < (svgdir "/" f)) > 0) print line
          close(svgdir "/" f)
          print "</figure>"
          next
        }
        /^<table>/ { print "<div class=\"tablewrap\">" }
        { print }
        /^<\/table>/ { print "</div>" }
      '
    printf '</body>\n</html>\n'
  } >"$2"
}

finish() {
  local end_iso end_ns span TIMELINE_NOTE
  now
  end_iso="$NOW_ISO" end_ns="$NOW_NS"
  span="$(((end_ns - START_NS) / 1000000000))"
  event "$end_iso" "$end_ns" "$ROUND" run-stop "" "" "" "" "" \
    "${STOP_REASON:-completed}; killed=$KILLS skipped=$SKIPS failed=$FAILURES"

  log "Done"
  info "$([ "$DRY_RUN" -eq 1 ] && echo "would have killed" || echo "killed") $KILLS, skipped $SKIPS, failed $FAILURES, over ${span}s"
  info "events: $EVENTS"

  [ "$REPORT" = none ] && return 0

  # Paired once; all three charts read it.
  pair_kills "$EVENTS" "$span" >"$TMP/pairs"
  timeline_svg "$TMP/pairs" "$span" >"$OUTDIR/timeline.svg"
  heatmap_svg "$TMP/pairs" "$span" >"$OUTDIR/heatmap.svg"
  recovery_svg "$TMP/pairs" "$span" >"$OUTDIR/recovery.svg"
  histogram_svg "$TMP/pairs" >"$OUTDIR/histogram.svg"

  # The timeline stops being readable somewhere around fifty kills — the marks
  # merge and the bars go sub-pixel. It is still drawn, because nothing else
  # shows the individual events, but the report says so rather than leaving
  # someone to squint at it and wonder whether it is broken.
  TIMELINE_NOTE=""
  if [ "$KILLS" -gt 50 ]; then
    TIMELINE_NOTE="
**$KILLS kills is past what this chart can show.** The marks merge and each bar
is a pixel or two wide; read the heatmap above for when, and the scatter for how
long. This one is kept for the hover text, which still names every pod.
"
  fi

  report_md "$EVENTS" "$end_iso" "$span" >"$OUTDIR/report.md"
  info "report: $OUTDIR/report.md"

  if [ "$REPORT" = html ]; then
    if command -v cmark-gfm >/dev/null 2>&1; then
      render_html "$OUTDIR/report.md" "$OUTDIR/report.html" "$OUTDIR"
      info "report: $OUTDIR/report.html"
    else
      warn "cmark-gfm not on PATH — the report stays as Markdown"
    fi
  fi

  if [ "$HOLD" -gt 0 ]; then
    info "holding the container open for ${HOLD}s so the report can be copied out"
    # STOP is already 1 by the time finish() runs after a signal, which would
    # make nap() return instantly and defeat the hold — so this waits on its
    # own, on the signal count rather than the flag. A second signal still ends
    # it: bash runs the handler as soon as the sleep it interrupted returns,
    # and these sleeps are one second long.
    local left="$HOLD" before="$SIGNALS"
    while [ "$left" -gt 0 ] && [ "$SIGNALS" -eq "$before" ]; do
      sleep 1
      left=$((left - 1))
    done
  fi
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

# Everything below is a function, and nothing runs until the last line of the
# file. That is not style — bash reads a script incrementally, parsing and
# executing one command at a time and seeking on, so a script that is edited,
# copied over or `git pull`ed while it runs leaves bash reading from an offset
# that now lands in the middle of something else. What comes out is a syntax
# error at a line that was fine when it started:
#
#   ./storage-chaos.sh: line 1664: unexpected EOF while looking for matching `"'
#   ./storage-chaos.sh: line 1133: syntax error near unexpected token `||'
#
# Both were seen here, and neither was a bug in the file. Reaching `main "$@"`
# obliges bash to have parsed every line above it first, so a run that has
# started is running from memory and cannot be affected by the file changing
# underneath it. A run can take hours; that is a long time to hold a file still.
#
# The rule this imposes: no statement with an effect belongs at the top level.
# Plain assignments of constants are fine and stay where they read best.

# The candidate set, or a reason there is none.
check_candidates() {
  CANDIDATES="$(wc -l <"$CAND")"
  if [ "$CANDIDATES" -eq 0 ]; then
    echo "nothing to kill in ${NAMESPACES[*]} — $(why_empty)" >&2
    exit 1
  fi
  [ -n "$LISTING_ERR" ] && warn "$LISTING_ERR"
}

# plan.txt and config.env, both written before anything is killed so an
# interrupted run still records what it was going to do.
write_plan() {
  {
    printf 'storage-chaos plan\n\n'
    printf 'generated:  %s\n' "$START_ISO"
    printf 'namespaces: %s\n' "${NAMESPACES[*]}"
    printf 'output:     %s\n' "$OUTDIR"
    printf 'candidates: %s\n\n' "$CANDIDATES"
    printf 'configuration (set = came from the environment)\n'
    config_lines | awk -F'\t' '{ printf "  %-14s %-28s %s\n", $1, ($2 == "" ? "<empty>" : $2), $3 }'
    printf '\nkill order (first cycle; random mode reshuffles on each one)\n'
    # The plan is written before anything is killed, so an interrupted run still
    # leaves a record of what it was going to do.
    plan_for_cycle 1 | awk -v cand="$CAND" '
      BEGIN { while ((getline l < cand) > 0) { split(l, f, "\t"); pod[f[1]] = f[2] "/" f[3]; node[f[1]] = f[4] } }
      { printf "%4d. %-46s %-42s %s\n", NR, $0, pod[$0], node[$0] }
    '
  } >"$PLANFILE"

  # The same configuration as something that can be fed straight back in, which
  # plan.txt's aligned columns cannot. Written every run, including dry ones,
  # because the commonest question about a chaos run a week later is "what were
  # the settings" and the second commonest is "run that again".
  {
    printf '# storage-chaos configuration for %s\n' "${RUNDIR:-$OUTBASE}"
    printf '#\n'
    printf '# Re-run this configuration, in any POSIX shell:\n'
    # Sourced rather than fed through `env $(...)`: that form relies on the
    # caller word-splitting an unquoted command substitution, which bash does
    # and zsh does not — there it passed the whole file as a single argument.
    # `set -a` exports every assignment, and the quoting below survives it.
    #
    # RUNDIR is unset rather than reused, so the repeat lands in its own
    # timestamped directory instead of overwriting the run being repeated.
    printf '#   set -a; . ./config.env; set +a; unset RUNDIR\n'
    printf '#   ./storage-chaos.sh %s\n' "${NAMESPACES[*]}"
    config_lines | awk -F'\t' '
      BEGIN { q = sprintf("%c", 39) }
      { v = $2; gsub(q, q "\\" q q, v); print $1 "=" q v q }
    '
  } >"$OUTDIR/config.env"
}

# The run banner and the full configuration, to the log and to events.csv.
banner() {
  log "storage-chaos"
  info "namespaces  ${NAMESPACES[*]}"
  info "candidates  $CANDIDATES pods${SELECTOR:+ matching $SELECTOR}"
  info "mode        $MODE$([ "$MODE" = random ] && echo " (seed $SEED)")"
  info "kill        $KILL_MODE, $BATCH per round, every ${INTERVAL}s"
  info "rounds      $([ "$ITERATIONS" -eq 0 ] && echo "until stopped" || echo "$ITERATIONS")$([ "$DURATION" -gt 0 ] && echo ", or ${DURATION}s")"
  info "output      $OUTDIR"
  [ "$DRY_RUN" -eq 1 ] && info "DRY RUN — nothing will be deleted"

  # The whole configuration, in the log, every run. The lines above are the
  # readable summary; this is the record — a run whose report is being argued
  # about a week later should not need anyone to remember what was exported.
  log "Configuration"
  # Formatted by awk rather than a `read k val src` loop: tab is IFS whitespace,
  # so bash collapses the two tabs around an empty value into one and every
  # column after it shifts left. awk with an explicit -F'\t' does not.
  while IFS= read -r line; do info "$line"; done < <(
    config_lines |
      awk -F'\t' '{ printf "%-14s %-28s %s\n", $1, ($2 == "" ? "<empty>" : $2), $3 }'
  )
  info "$(printf '%-14s %-28s %s' NAMESPACES "${NAMESPACES[*]}" argument)"

  event "$START_ISO" "$START_NS" 0 run-start "" "" "" "" "" \
    "namespaces='${NAMESPACES[*]}' candidates=$CANDIDATES $(config_oneline)"
}

over_budget() {
  local nns
  [ "$STOP" -eq 1 ] && return 0
  if [ "$ITERATIONS" -gt 0 ] && [ "$ROUND" -ge "$ITERATIONS" ]; then
    STOP=1
    STOP_REASON="iterations reached"
    return 0
  fi
  if [ "$DURATION" -gt 0 ]; then
    now
    nns="$NOW_NS"
    if [ "$(((nns - START_NS) / 1000000000))" -ge "$DURATION" ]; then
      STOP=1
      STOP_REASON="duration reached"
      return 0
    fi
  fi
  return 1
}

# The kill loop: cycles of the plan, rounds of BATCH within each.
run_loop() {
  cycle=0
  while ! over_budget; do
    cycle=$((cycle + 1))
    list_candidates
    mapfile -t plan < <(plan_for_cycle "$cycle")

    if [ ${#plan[@]} -eq 0 ]; then
      # Everything that matched at startup has gone. Worth waiting out rather
      # than exiting: a namespace whose pods are all being rescheduled is exactly
      # the moment a chaos run should keep watching — but it has to say what it
      # is seeing, or an expired token looks identical to a quiet cluster.
      now
      wiso="$NOW_ISO" wns="$NOW_NS"
      event "$wiso" "$wns" "$ROUND" no-candidates "" "" "" "" "" "$(why_empty)"
      warn "no candidate pods this cycle — $(why_empty); waiting ${INTERVAL}s"
      nap "$INTERVAL"
      continue
    fi

    [ -n "$LISTING_ERR" ] && warn "$LISTING_ERR"

    [ "$MODE" = random ] && info "cycle $cycle: ${#plan[@]} candidates, shuffled with seed $((SEED + cycle))"

    i=0
    while [ "$i" -lt "${#plan[@]}" ] && ! over_budget; do
      batch=("${plan[@]:i:BATCH}")
      i=$((i + BATCH))
      ROUND=$((ROUND + 1))

      # Re-listed immediately before the kill rather than reusing the cycle's
      # listing: between the plan and this round the pods have been replaced at
      # least once, and it is the pod holding the slot *now* that is meant.
      list_candidates
      : >"$TMP/wait"
      for key in "${batch[@]}"; do kill_key "$key"; done
      wait_for_recovery

      now
      riso="$NOW_ISO" rns="$NOW_NS"
      event "$riso" "$rns" "$ROUND" round-end "" "" "" "" "" "killed=$KILLS skipped=$SKIPS"

      over_budget && break
      [ "$INTERVAL" -gt 0 ] && nap "$INTERVAL"
    done
  done
}

main() {
  init_config "$@"
  mark_start
  init_output
  init_traps
  init_events
  preflight
  list_candidates
  check_candidates
  write_plan
  banner

  # The head start exists so the benchmark beside this has time to get past
  # its own setup — initdb, the fio layout pass — and be measuring something
  # by the time the first pod goes. A kill landing in the middle of a
  # benchmark's setup shows up as a slow setup and nothing else.
  if [ "$START_DELAY" -gt 0 ]; then
    info "waiting ${START_DELAY}s before the first kill"
    nap "$START_DELAY"
  fi

  run_loop
  finish
}

main "$@"
