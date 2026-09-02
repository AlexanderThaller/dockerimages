#!/usr/bin/env bash
#
# storage-bench.sh — fio + pgbench benchmark across one or more mounted PVCs,
#                    emitting CSV data files and a Markdown report.
#
# Usage:
#   ./storage-bench.sh /data/ceph /data/portworx
#   ORDER=by-test ./storage-bench.sh /data/ceph /data/portworx
#
# The graphs are drawn by awk itself — see render-chart.awk, materialised
# under graphs/ at startup — so nothing extra is needed for those. The
# rendered HTML report needs cmark-gfm, which a host does not necessarily
# have; it is in the image, and shell.nix puts it on a host too:
#   nix-shell --run './storage-bench.sh /tank/backup'
# Without it the benchmark still runs, it just leaves the report as Markdown
# and says so at the end.
#
# Run order (ORDER):
#   by-mount  (default)  full suite on mount 1, then full suite on mount 2.
#   by-test              each test run on every mount before moving to the next
#                        test. Pairs the two mounts closely in time, so shared
#                        backend load affects both roughly equally. Better for
#                        a head-to-head comparison; worse if you want each
#                        mount's run to be a clean uninterrupted block.
#
# In both modes tests always execute in the same order within a mount, so
# writes still precede the reads that depend on them.
#
# REPEATS runs the whole suite that many times over, rather than repeating each
# test in place. One pass is one sample of the storage as a whole, so a slow
# drift — a cache warming, a scrub starting, a neighbour waking up — moves a
# whole pass rather than hiding inside one test's repeats. It also keeps every
# pass ordered identically, which repeating in place would not.
#
# Each pass writes its own results, and the graphs are produced twice over: once
# per pass, and once aggregated across passes as a mean with the spread drawn
# behind it. The spread is the reason the default is three rather than one: a
# single pass cannot distinguish a slow backend from a backend that was slow
# once, and it reports that unlucky number with just as much confidence.
#
# Three passes therefore cost roughly three times the wall clock of one. REPEATS=1
# restores the old behaviour and skips the aggregate entirely, since there would
# be nothing to average.
#
# Tunables (env vars):
#   OUTBASE       directory the run dir goes in (default /tmp)
#   LABEL         appended to the default RUNDIR (default none)
#   RUNDIR        this run's directory inside it
#                                               (default bench-results-<timestamp>,
#                                                or bench-results-<timestamp>-<LABEL>
#                                                if LABEL is set; set RUNDIR itself
#                                                empty to write straight into OUTBASE)
#   ORDER         by-mount | by-test            (default by-mount)
#   REPEATS       times to run the whole suite  (default 3)
#   SETTLE        seconds to idle between runs  (default 15)
#   TEST_SETTLE   seconds to idle between tests (default 1)
#   FIO_TESTS     comma/space-separated subset
#                 of the fio jobs to run        (default all eight)
#   FIO_SIZE      fio working set per job       (default 10G)
#   FIO_RUNTIME   seconds per fio job           (default 60)
#   IOENGINE      fio ioengine                  (default libaio)
#   LOG_AVG_MSEC  fio time-series sample window (default 100)
#   PGBENCH       1|0, run the postgres workload(default 1)
#   PGBENCH_SCALE pgbench scale factor          (default 100, ~1.6 GiB)
#   PGBENCH_CLIENTS  concurrent pgbench clients (default 8)
#   PGBENCH_JOBS  pgbench worker threads        (default 4)
#   PGBENCH_TIME  seconds of measured pgbench   (default 300)
#   PGBENCH_WARMUP   seconds of unmeasured run
#                 before it                     (default 30)
#   PGBENCH_MODE  simple | extended | prepared  (default prepared)
#   PGBENCH_MAX_WAL  postgres max_wal_size      (default 4GB)
#   PLOT          1|0, draw the graphs          (default 1)
#   RENDER        html|none                     (default html)
#   ARCHIVE       1|0, tar.gz the run directory  (default 1)
#
# fio measures the storage directly. pgbench measures what a real application
# gets out of it: a throwaway PostgreSQL cluster is initialised on each mount in
# turn, loaded, and driven through the built-in TPC-B-like workload. The numbers
# are lower than fio's and that is the point — they carry the WAL, the
# checkpointer and the page cache that sit between an application and the disk,
# none of which fio models.
#
# There used to be three dd tests here and there are now two more fio jobs
# instead. dd was doing three things: a 1 MiB sequential write of zeros, the
# same write from /dev/urandom, and a sequential read back with O_DIRECT. The
# read is `seq_read_1m` and always was — same block size, same direction, and
# O_DIRECT without dd's fallback to the page cache. The writes measured what the
# backend does with the *content*, and that is now `seq_write_zero_1m` and
# `seq_write_rand_1m`: `seq_write_1m` with one flag changed each, so all three
# are directly comparable, and all three carry the time series, the IOPS and the
# latency columns that dd's single parsed-out throughput figure never had.
#
# Runs unprivileged — no root, no SCC changes needed. PostgreSQL refuses to run
# as root, so the pgbench workload is skipped rather than run in that case.

set -uo pipefail
export LC_ALL=C

# --replot <dir> skips the benchmark entirely and rebuilds the graphs and the
# report from a previous run's own output — its fio-logs/, pgbench logs and
# CSVs are all that redrawing needs, so a change to the drawing or reporting
# code can be tried against a real run without paying for fio and pgbench
# again. REPLOT_DIR being set is what every section below that touches a
# mount, runs fio/pgbench or writes RUNDIR guards itself on.
REPLOT_DIR=""
if [ "${1:-}" = "--replot" ]; then
  REPLOT_DIR="${2:-}"
  [ -n "$REPLOT_DIR" ] && [ -d "$REPLOT_DIR" ] || {
    echo "Usage: $0 --replot <results-dir>" >&2
    exit 1
  }
  shift 2
fi

MOUNTS=("$@")
if [ -z "$REPLOT_DIR" ]; then
  [ ${#MOUNTS[@]} -eq 0 ] && echo "Usage: $0 <mount1> [<mount2> ...] | --replot <results-dir>" >&2 && exit 1
fi

# Where the results go, in two parts, so that pointing the benchmark at a
# mounted volume does not also flatten every run into the same directory. The
# volume is OUTBASE and stays put; RUNDIR is per-run and carries the timestamp,
# so consecutive runs sit side by side instead of overwriting each other.
#
# OUTDIR is still read, as the base, because that is the variable callers were
# passing the volume in before this was split — an old `OUTDIR=/out` now means
# `/out/bench-results-<timestamp>` rather than being silently ignored. Setting
# RUNDIR empty restores the flat behaviour.
#
# LABEL only shapes the default: it is folded into RUNDIR's fallback, so an
# explicit RUNDIR still wins outright and a run named RUNDIR=before-upgrade
# does not also grow a redundant -$LABEL suffix.
#
# --replot bypasses all of this and points OUTDIR straight at the directory
# it was given — there is no OUTBASE/RUNDIR split for a run that already has
# a directory.
if [ -n "$REPLOT_DIR" ]; then
  OUTDIR="${REPLOT_DIR%/}"
  # Empty rather than unset: the archive step (see Archive, below) treats an
  # empty RUNDIR as "the run directory already exists, archive it in place" —
  # exactly what replotting an existing directory needs, and it does not
  # reference OUTBASE on this path, so that one is left genuinely unset.
  RUNDIR=""
else
  TS="$(date +%Y%m%d-%H%M%S)"
  OUTBASE="${OUTBASE:-${OUTDIR:-/tmp}}"
  LABEL="${LABEL:-}"
  RUNDIR="${RUNDIR-bench-results-$TS${LABEL:+-$LABEL}}"
  OUTDIR="$OUTBASE${RUNDIR:+/$RUNDIR}"
fi
ORDER="${ORDER:-by-mount}"
REPEATS="${REPEATS:-3}"
SETTLE="${SETTLE:-15}"

# A short pause between consecutive tests on the same mount. SETTLE is the long
# cooldown between whole runs; this is the small one between the jobs inside a
# run, where there used to be no gap at all. A test that ends with a queue of
# dirty pages still being written back would otherwise have that writeback
# land inside the first samples of the test after it — visible on the graphs as
# a start that is slower than the rest of the run and belongs to the previous
# job. One second is enough to drain what a fio job leaves behind; it is not
# enough to let a backend recover, which is what SETTLE is for.
TEST_SETTLE="${TEST_SETTLE:-1}"
FIO_SIZE="${FIO_SIZE:-10G}"
FIO_RUNTIME="${FIO_RUNTIME:-60}"
IOENGINE="${IOENGINE:-libaio}"
LOG_AVG_MSEC="${LOG_AVG_MSEC:-100}"
PGBENCH="${PGBENCH:-1}"
PGBENCH_SCALE="${PGBENCH_SCALE:-100}"
PGBENCH_CLIENTS="${PGBENCH_CLIENTS:-8}"
PGBENCH_JOBS="${PGBENCH_JOBS:-4}"
PGBENCH_TIME="${PGBENCH_TIME:-300}"

# An unmeasured run before the measured one. The first seconds of a pgbench run
# are not the workload: the caches are cold, the WAL has just been recycled and
# no checkpoint has happened yet, so the transaction rate starts high and decays
# into whatever the storage can actually sustain. Measuring from cold reports
# that decay as if it were the result. The warmup absorbs it, and the measured
# run then starts in the state the database would be in after a few minutes of
# real traffic. Set it to 0 to measure from cold deliberately.
PGBENCH_WARMUP="${PGBENCH_WARMUP:-30}"

# Query protocol. pgbench's default is `simple`, which sends every statement as
# text and has the server parse and plan it again each time — at which point a
# good deal of what is being measured is postgres parsing SQL rather than the
# storage underneath it. Real applications and every connection pooler use
# prepared statements, so `prepared` both loads the storage harder and looks
# more like production. `simple` and `extended` are still available for
# comparison.
PGBENCH_MODE="${PGBENCH_MODE:-prepared}"

# postgres checkpoints when max_wal_size is reached, and the 1 GB default means
# a mount that can absorb writes quickly checkpoints every few seconds — a
# pathology of the default rather than anything a tuned database does, and it
# dominates the run. 4 GB is a conservative production setting and gives a
# checkpoint cadence the graphs can actually show as an event.
PGBENCH_MAX_WAL="${PGBENCH_MAX_WAL:-4GB}"
PLOT="${PLOT:-1}"
RENDER="${RENDER:-html}"

# Tar the finished run directory up, so what has to be copied off the machine
# that was measured is one file rather than a few thousand.
ARCHIVE="${ARCHIVE:-1}"

# pgbench aggregates its own log into fixed intervals and one second is the
# finest it accepts, so unlike LOG_AVG_MSEC this is not a tunable — it is the
# floor. It is named here because the report quotes it and pgbench_series
# divides by it.
PGBENCH_AGG_INTERVAL=1

case "$ORDER" in
by-mount | by-test) ;;
*)
  echo "ORDER must be 'by-mount' or 'by-test' (got '$ORDER')" >&2
  exit 1
  ;;
esac

# The sample window doubles as the bucket width when the per-job samples are
# folded together, so it has to be a positive integer.
#
# 100ms is a floor worth thinking before going under. Two things break down as
# the window shrinks. fio averages whatever I/Os completed inside it, so on
# slow storage a short window holds only a handful of them and the line becomes
# a hash of quantisation steps rather than a measurement — at 200 IOPS a 20ms
# window sees four I/Os. And concurrent jobs timestamp their samples a
# millisecond or two apart, which fio_series absorbs by rounding onto the
# nearest window boundary; that has margin at 100ms and very little at 10ms,
# and a sample landing in the wrong bucket shows up as a sawtooth, because
# throughput is summed across jobs.
case "$LOG_AVG_MSEC" in
'' | *[!0-9]*)
  echo "LOG_AVG_MSEC must be a positive integer (got '$LOG_AVG_MSEC')" >&2
  exit 1
  ;;
esac
[ "$LOG_AVG_MSEC" -ge 1 ] || {
  echo "LOG_AVG_MSEC must be >= 1 (got '$LOG_AVG_MSEC')" >&2
  exit 1
}

# HTML only. Anything else — PDF, DOCX — means pandoc, and pandoc is a Haskell
# binary several times the size of everything else in this image put together,
# for output formats nobody was reading. The Markdown is kept next to the HTML,
# so pandoc on any host that has it still gets you one.
case "$RENDER" in
html | none) ;;
*)
  echo "RENDER must be one of html|none (got '$RENDER')" >&2
  exit 1
  ;;
esac

# Checked up front rather than left to pgbench, which would otherwise fail an
# hour into the run, after fio has already been paid for.
for v in REPEATS PGBENCH_SCALE PGBENCH_CLIENTS PGBENCH_JOBS PGBENCH_TIME; do
  case "${!v}" in
  '' | *[!0-9]*)
    echo "$v must be a positive integer (got '${!v}')" >&2
    exit 1
    ;;
  esac
  [ "${!v}" -ge 1 ] || {
    echo "$v must be >= 1 (got '${!v}')" >&2
    exit 1
  }
done

# Zero is meaningful for the warmup — it is how you ask to measure from cold —
# so it is checked separately from the ones that must be at least one.
case "$PGBENCH_WARMUP" in
'' | *[!0-9]*)
  echo "PGBENCH_WARMUP must be a non-negative integer (got '$PGBENCH_WARMUP')" >&2
  exit 1
  ;;
esac

case "$PGBENCH_MODE" in
simple | extended | prepared) ;;
*)
  echo "PGBENCH_MODE must be one of simple|extended|prepared (got '$PGBENCH_MODE')" >&2
  exit 1
  ;;
esac

# pgbench divides its clients between its threads and refuses the run outright
# if the division leaves a thread with none.
[ "$PGBENCH_JOBS" -le "$PGBENCH_CLIENTS" ] || {
  echo "PGBENCH_JOBS ($PGBENCH_JOBS) cannot exceed PGBENCH_CLIENTS ($PGBENCH_CLIENTS)" >&2
  exit 1
}

FIO_CSV="$OUTDIR/fio_results.csv"
PG_CSV="$OUTDIR/pgbench_results.csv"
MD="$OUTDIR/storage-benchmark-report.md"
PLOTDIR="$OUTDIR/graphs" # the SVGs the report embeds

# Anything a pass produces is written under its own directory, because a second
# pass would otherwise overwrite the first: fio names its logs after the test,
# not after the attempt. RAWDIR, LOGDIR and PLOTDATA are repointed at the
# current pass by set_run_paths; the run_* functions read them as globals and
# do not need to know how many passes there are.
#
# Run ids are zero-padded so that graphs/ and raw/ sort in execution order in a
# file browser rather than putting run-10 next to run-1.
RUN_ID=""
RAWDIR=""
LOGDIR=""
PLOTDATA=""

run_id_for() { printf 'run-%02d' "$1"; }

set_run_paths() { # <pass number>
  RUN_ID="$(run_id_for "$1")"
  RAWDIR="$OUTDIR/raw/$RUN_ID"
  LOGDIR="$OUTDIR/fio-logs/$RUN_ID"
  PLOTDATA="$PLOTDIR/data/$RUN_ID"
  mkdir -p "$RAWDIR" "$LOGDIR" "$PLOTDATA" || {
    echo "cannot create $OUTDIR/$RUN_ID" >&2
    exit 1
  }
}

# df and /proc/mounts are properties of the mount rather than of a pass, so they
# are captured once and live above the per-pass directories.
MOUNTINFO="$OUTDIR/raw"

mkdir -p "$MOUNTINFO" "$PLOTDIR" || {
  echo "cannot create $OUTDIR" >&2
  exit 1
}

# The fio jobs, in execution order. Read tests depend on the write test that
# precedes them (seq_read_1m reads fio_seq.dat back, rand_read_4k reads
# fio_rand.dat back), so this order matters in both ORDER modes, and selecting
# a read job without its write job in FIO_TESTS below still works but costs
# that read job an unmeasured setup pass: fio lays the file out itself before
# timing starts, rather than reading one the run already wrote.
ALL_FIO_TESTS=(
  seq_write_1m
  seq_write_zero_1m
  seq_write_rand_1m
  seq_read_1m
  rand_write_4k
  rand_read_4k
  rand_rw_70_30_4k
  fsync_8k_qd1
)

# FIO_TESTS narrows ALL_FIO_TESTS to a comma- or space-separated subset,
# e.g. FIO_TESTS=rand_rw_70_30_4k or FIO_TESTS="rand_write_4k,rand_read_4k".
# Unset or empty runs all of them, as before. The result always keeps
# ALL_FIO_TESTS's order regardless of how the subset was listed, since that
# order is what keeps the write-then-read dependency intact.
#
# pgbench is not part of this list — it stays its own on/off switch, PGBENCH,
# because "not selected in FIO_TESTS" and "postgres unavailable" are different
# reasons for the same absence and the report explains them differently.
TESTS=()
if [ -n "${FIO_TESTS:-}" ]; then
  declare -A _want_test=()
  for _t in ${FIO_TESTS//,/ }; do
    case " ${ALL_FIO_TESTS[*]} " in
    *" $_t "*) _want_test["$_t"]=1 ;;
    *)
      echo "FIO_TESTS: unknown test '$_t' — choose from: ${ALL_FIO_TESTS[*]}" >&2
      exit 1
      ;;
    esac
  done
  for _t in "${ALL_FIO_TESTS[@]}"; do
    [ -n "${_want_test[$_t]:-}" ] && TESTS+=("$_t")
  done
  unset _t _want_test
else
  TESTS=("${ALL_FIO_TESTS[@]}")
fi
TESTS+=(pgbench)

# Filled in by run_fio, read by the report: test name -> the flags it was given.
declare -A FIO_ARGS=()

CREATED=()

# pgbench state that has to survive a Ctrl-C: a running postmaster keeps the
# mount busy and holds its data directory open, and the clusters are large
# enough (PGBENCH_SCALE 100 is ~1.6 GiB) that leaving them behind on someone's
# storage is not acceptable.
PG_DATADIRS=() # every cluster initdb created, across all mounts
PG_ACTIVE=""   # the one with a postmaster currently up, if any
PG_SOCKDIR=""

cleanup() {
  echo
  echo "Cleaning up test files..."
  for f in "${CREATED[@]:-}"; do [ -n "$f" ] && rm -f "$f"; done

  if [ -n "$PG_ACTIVE" ]; then
    echo "Stopping postgres..."
    pg_ctl -D "$PG_ACTIVE" -m immediate -w stop >/dev/null 2>&1
    PG_ACTIVE=""
  fi
  # The PG_VERSION test is what makes the rm -rf safe: it fires only on a
  # directory postgres itself created, never on a mount point that a bad
  # expansion happened to name.
  for d in "${PG_DATADIRS[@]:-}"; do
    [ -n "$d" ] && [ -f "$d/PG_VERSION" ] && rm -rf "$d"
  done
  [ -n "$PG_SOCKDIR" ] && rm -rf "$PG_SOCKDIR"
}
trap cleanup EXIT INT TERM

log() { printf '\n=== %s ===\n' "$*"; }
info() { printf '  %s\n' "$*"; }

slug() { echo "${1#/}" | tr '/' '_'; }

settle() {
  [ "$SETTLE" -gt 0 ] 2>/dev/null || return 0
  info "settling ${SETTLE}s..."
  sleep "$SETTLE"
}

# Quieter than settle(): it runs between every pair of tests, so announcing
# itself each time would bury the results it sits between.
test_settle() {
  [ "$TEST_SETTLE" -gt 0 ] 2>/dev/null || return 0
  sleep "$TEST_SETTLE"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[ -n "$REPLOT_DIR" ] || command -v fio >/dev/null 2>&1 || {
  echo "fio not found in PATH" >&2
  exit 1
}

# Graphs and rendering are optional extras: a missing tool degrades the report
# rather than failing the benchmark, which by then has already been paid for.
# MISSING collects what was degraded so it can be repeated at the end — a
# benchmark runs for long enough that a warning printed up here has scrolled
# well out of sight by the time anyone looks at the results.
MISSING=()

# Drawing is awk against the reduced .dat series, same as the rest of the
# script's parsing — there is no external tool to be missing, so this is
# purely the PLOT=0 opt-out rather than a degraded-mode check.
have_plot=0
[ "$PLOT" = "1" ] && have_plot=1

if [ "$RENDER" != "none" ] && ! command -v cmark-gfm >/dev/null 2>&1; then
  echo "NOTE cmark-gfm not found in PATH — report stays as Markdown source" >&2
  MISSING+=("cmark-gfm — the report was not rendered")
  RENDER=none
fi

# PostgreSQL resolves the uid it is running as through getpwuid() and treats a
# failed lookup as fatal — initdb stops at "could not look up effective user
# ID". In a container that is the normal case, not the exception: the image
# knows root and nobody, and the benchmark is deliberately run under the
# caller's uid so the reports are not left root-owned. The image therefore
# ships /etc/passwd as a writable file rather than the usual read-only symlink
# into the store, and this adds the missing line. On a host the entry is
# already there and nothing is written.
ensure_passwd_entry() {
  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"
  has_passwd_entry() { awk -F: -v u="$uid" '$3 == u { f = 1 } END { exit !f }' /etc/passwd 2>/dev/null; }

  has_passwd_entry && return 0
  [ -w /etc/passwd ] || return 1
  printf 'storagebench:x:%s:%s:storage-bench:%s:/bin/sh\n' \
    "$uid" "$gid" "${HOME:-/tmp}" >>/etc/passwd
  has_passwd_entry
}

# Read whether or not the workload ends up running: the report header states
# what postgres is in the image, which is a different question from whether it
# was used, and `PGBENCH=0` should not blank out the answer.
PG_VERSION="$(postgres --version 2>/dev/null | awk '{print $NF}')"
[ -n "$PG_VERSION" ] || PG_VERSION="not present"

# The line in /proc/mounts for the filesystem a path is *on*: the longest mount
# point that prefixes it, which is the same rule df applies.
#
# This used to be `grep -F "$mp" /proc/mounts`, which answers correctly when the
# path under test is itself a mount point and answers nothing at all when it is
# a directory inside one — so the report's mount section was silently empty for
# `./storage-bench.sh /tank/backup/scratch`, and for every `--tmpfs`-backed
# smoke run, without ever saying why.
owning_mount() { # <path>
  awk -v p="$1" '
    {
      m = $2
      pre = (m == "/" ? "/" : m "/")
      if ((m == p || index(p, pre) == 1) && length(m) > length(best_m)) {
        best_m = m
        best = $0
      }
    }
    END { if (best != "") print best }
  ' /proc/mounts
}

if [ -n "$REPLOT_DIR" ]; then
  # Nothing here touches a mount, runs fio/pgbench, or truncates a CSV — all
  # of that already happened in the run being replotted. USABLE, have_pgbench
  # and PG_VERSION are recovered from what that run left behind instead.
  [ -f "$FIO_CSV" ] || {
    echo "$FIO_CSV not found — $REPLOT_DIR does not look like a storage-bench results directory" >&2
    exit 1
  }
  readarray -t USABLE < <(tail -n +2 "$FIO_CSV" | awk -F, '!seen[$2]++ { print $2 }')
  if [ ${#USABLE[@]} -eq 0 ]; then
    echo "No mounts found in $FIO_CSV. Nothing to replot." >&2
    exit 1
  fi

  have_pgbench=0
  [ -s "$PG_CSV" ] && [ "$(wc -l <"$PG_CSV")" -gt 1 ] && have_pgbench=1

  # Best-effort: the original report's own property table, which is more
  # likely to be right than a live `postgres --version` on whatever machine
  # is replotting this.
  if [ -f "$MD" ]; then
    v="$(awk -F'|' '$2 ~ /postgres version/ { gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit }' "$MD")"
    [ -n "$v" ] && PG_VERSION="$v"
  fi

  # Same idea, for the tunables that only shape the report's prose and
  # headings — ORDER, SETTLE and the rest never affect what gets redrawn
  # (fio_series/pgbench_series read the raw logs fresh every time), but a
  # replotted report claiming today's defaults for a run that overrode them
  # would be actively misleading rather than merely incomplete. Silently
  # keeps today's environment/defaults for anything the old report does not
  # have — an old run predating this table, or one with RENDER=none — since
  # that is exactly what those already are.
  if [ -f "$MD" ]; then
    load_replot_param() { # <label as it appears in the old table> <var name>
      local val
      val="$(awk -F'|' -v want="$2" '
        { gsub(/^[ \t]+|[ \t]+$/, "", $2) }
        $2 == want { gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit }
      ' "$1")"
      [ -n "$val" ] && printf '%s' "$val"
    }
    v="$(load_replot_param "$MD" "Run order")"; [ -n "$v" ] && ORDER="$v"
    v="$(load_replot_param "$MD" "Settle between runs")"; [ -n "$v" ] && SETTLE="${v%s}"
    v="$(load_replot_param "$MD" "Settle between tests")"; [ -n "$v" ] && TEST_SETTLE="${v%s}"
    v="$(load_replot_param "$MD" "fio working set")"; [ -n "$v" ] && FIO_SIZE="$v"
    v="$(load_replot_param "$MD" "fio runtime per job")"; [ -n "$v" ] && FIO_RUNTIME="${v%s}"
    v="$(load_replot_param "$MD" "fio ioengine")"; [ -n "$v" ] && IOENGINE="$v"
    v="$(load_replot_param "$MD" "fio log sample window")"; [ -n "$v" ] && LOG_AVG_MSEC="${v%ms}"
    unset -f load_replot_param
  fi

  echo "Replotting   : $OUTDIR"
  echo "Mounts       : ${USABLE[*]}"
else
  USABLE=()
  for mp in "${MOUNTS[@]}"; do
    if [ ! -d "$mp" ]; then
      echo "SKIP $mp — not a directory" >&2
      continue
    fi
    if ! touch "$mp/.writetest.$$" 2>/dev/null; then
      echo "SKIP $mp — not writable by uid $(id -u)" >&2
      continue
    fi
    rm -f "$mp/.writetest.$$"
    USABLE+=("$mp")
  done

  if [ ${#USABLE[@]} -eq 0 ]; then
    echo "No usable mount points. Nothing to do." >&2
    exit 1
  fi

  echo "Benchmarking : ${USABLE[*]}"
  echo "Run order    : $ORDER"
  echo "Settle       : ${SETTLE}s between runs, ${TEST_SETTLE}s between tests"
  echo "Results dir  : $OUTDIR"

  have_pgbench=0
  if [ "$PGBENCH" = "1" ]; then
    if [ "$(id -u)" -eq 0 ]; then
      echo "NOTE running as uid 0 — postgres refuses to run as root, skipping pgbench" >&2
      MISSING+=("pgbench — skipped, postgres will not run as root")
    elif ! command -v initdb >/dev/null 2>&1 ||
      ! command -v pg_ctl >/dev/null 2>&1 ||
      ! command -v pgbench >/dev/null 2>&1; then
      echo "NOTE postgres not found in PATH — the report will have NO PGBENCH RESULTS" >&2
      MISSING+=("postgresql — the pgbench workload did not run")
    elif ! ensure_passwd_entry; then
      echo "NOTE uid $(id -u) has no /etc/passwd entry and it is not writable —" >&2
      echo "     postgres cannot start, skipping pgbench" >&2
      MISSING+=("passwd entry for uid $(id -u) — the pgbench workload did not run")
    else
      have_pgbench=1
    fi
  fi

  # The socket lives off the mount under test, in TMPDIR, for two reasons: a
  # unix socket on the storage being hammered is not something to measure, and
  # the path has to fit in sockaddr_un.sun_path, which is 108 bytes including
  # the ".s.PGSQL.5432" the server appends. A deep OUTDIR would blow that;
  # TMPDIR usually will not, and if it does the workload is skipped rather
  # than failing halfway through the run.
  if [ "$have_pgbench" = 1 ]; then
    PG_SOCKDIR="$(mktemp -d 2>/dev/null)"
    if [ -z "$PG_SOCKDIR" ] || [ ${#PG_SOCKDIR} -gt 90 ]; then
      echo "NOTE cannot make a short enough socket directory under ${TMPDIR:-/tmp} —" >&2
      echo "     skipping pgbench (unix socket paths are limited to 108 bytes)" >&2
      MISSING+=("pgbench — no usable socket directory under ${TMPDIR:-/tmp}")
      [ -n "$PG_SOCKDIR" ] && rmdir "$PG_SOCKDIR" 2>/dev/null
      PG_SOCKDIR=""
      have_pgbench=0
    fi
  fi

  # Register the files we will create so cleanup can remove them.
  for mp in "${USABLE[@]}"; do
    CREATED+=("$mp/fio_seq.dat" "$mp/fio_seq_zero.dat" "$mp/fio_seq_rand.dat"
      "$mp/fio_rand.dat" "$mp/fio_mix.dat" "$mp/fio_sync.dat")
    sl="$(slug "$mp")"
    df -h "$mp" >"$MOUNTINFO/df_${sl}.txt" 2>&1
    # /proc/mounts rather than mount(8): the same device/fstype/options in the
    # same fstab columns, and it keeps util-linux out of the image entirely,
    # which was ~25 MB once its PAM and systemd links are counted. mount(8) is
    # the fallback for a host that has no /proc, and gets the old substring
    # match because its output is not in the same columns.
    if [ -r /proc/mounts ]; then
      owning_mount "$mp" >"$MOUNTINFO/mount_${sl}.txt" 2>&1
    elif command -v mount >/dev/null 2>&1; then
      mount | grep -F "$mp" >"$MOUNTINFO/mount_${sl}.txt" 2>&1
    fi
  done

  echo "run,mount,test,read_iops,read_bw_kibs,read_clat_mean_us,write_iops,write_bw_kibs,write_clat_mean_us" >"$FIO_CSV"
  [ "$have_pgbench" = 1 ] &&
    echo "run,mount,scale,clients,threads,mode,warmup_s,duration_s,init_s,tps,latency_avg_ms,transactions,failed" >"$PG_CSV"
fi

# ---------------------------------------------------------------------------
# fio helper
#
# Uses terse v3 output: semicolon-separated with fixed field positions.
#   $7  read bw KiB/s   $8  read IOPS    $16 read clat mean (us)
#   $48 write bw KiB/s  $49 write IOPS   $57 write clat mean (us)
# Full terse lines are archived under raw/ if you want percentiles later.
#
# --write_{bw,iops,lat}_log additionally dump the run as a time series, one
# sample per LOG_AVG_MSEC window, which is what the graphs are built from.
# per_job_logs=0 puts every job's samples in one file rather than one file per
# job; note that it concatenates them, it does not merge them, so multi-job
# samples still have to be summed per timestamp when plotting.
# ---------------------------------------------------------------------------
run_fio() {
  local mp="$1" name="$2"
  shift 2
  local sl
  sl="$(slug "$mp")"
  local raw="$RAWDIR/fio_${sl}_${name}.terse"
  local out rc line row

  # Recorded so the report's per-test section can quote what actually ran
  # instead of a hand-copied duplicate that drifts the first time a flag here
  # changes. Every mount runs a test with the same flags — only --directory
  # differs, and that is added below — so the last writer winning is fine.
  FIO_ARGS["$name"]="$*"

  info "fio $name ..."
  out="$(fio --output-format=terse --terse-version=3 \
    --directory="$mp" --group_reporting \
    --write_bw_log="$LOGDIR/${sl}_${name}" \
    --write_iops_log="$LOGDIR/${sl}_${name}" \
    --write_lat_log="$LOGDIR/${sl}_${name}" \
    --log_avg_msec="$LOG_AVG_MSEC" --per_job_logs=0 "$@" 2>&1)"
  rc=$?
  printf '%s\n' "$out" >"$raw"

  line="$(printf '%s\n' "$out" | grep -E '^[0-9]+;' | tail -1)"

  if [ $rc -ne 0 ] || [ -z "$line" ]; then
    info "  FAILED (see $raw)"
    echo "$RUN_ID,$mp,$name,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED" >>"$FIO_CSV"
    return 1
  fi

  row="$(printf '%s\n' "$line" | awk -F';' -v OFS=, '{print $8, $7, $16, $49, $48, $57}')"
  info "  read: $(echo "$row" | cut -d, -f1) IOPS / write: $(echo "$row" | cut -d, -f4) IOPS"
  echo "$RUN_ID,$mp,$name,$row" >>"$FIO_CSV"
}

# ---------------------------------------------------------------------------
# pgbench
#
# A throwaway PostgreSQL cluster per mount, initialised on the storage under
# test, loaded with pgbench's TPC-B-like schema and then driven for a fixed
# time. Where fio asks how many 8 KiB writes the device can retire, this asks
# what a database actually gets: every transaction here carries a WAL write and
# an fsync at commit, a heap and index update that the checkpointer has to
# write back later, and full-page images after each checkpoint.
#
# Settings are stated on the command line rather than edited into
# postgresql.conf, so the cluster on disk is stock and the report can quote
# exactly what was changed. The three durability settings are already the
# defaults; they are named because they are the ones that make this a storage
# benchmark rather than a memory benchmark, and a future postgres that shipped
# different defaults would otherwise silently change what is measured.
#
# shared_buffers is deliberately left at its 128 MB default. A cluster that
# cached the whole working set would report the speed of RAM.
# ---------------------------------------------------------------------------
pg_conf_args() {
  printf '%s' \
    "-c listen_addresses='' " \
    "-c unix_socket_directories=$PG_SOCKDIR " \
    "-c fsync=on " \
    "-c synchronous_commit=on " \
    "-c full_page_writes=on " \
    "-c max_wal_size=$PGBENCH_MAX_WAL " \
    "-c max_connections=$((PGBENCH_CLIENTS + 8))"
}

run_pgbench() { # <mount>
  local mp="$1" sl pgdata prefix raw out rc
  local init_s tps lat txns failed

  sl="$(slug "$mp")"
  pgdata="$mp/pgdata"
  prefix="$LOGDIR/pgbench_${sl}"
  raw="$RAWDIR/pgbench_${sl}.txt"

  local failrow="$RUN_ID,$mp,$PGBENCH_SCALE,$PGBENCH_CLIENTS,$PGBENCH_JOBS,$PGBENCH_MODE,$PGBENCH_WARMUP,$PGBENCH_TIME,FAILED,FAILED,FAILED,FAILED,FAILED"

  # A cluster left behind by an earlier run would mean measuring a load that
  # never happened, so each run starts from initdb.
  rm -rf "$pgdata"
  PG_DATADIRS+=("$pgdata")

  info "pgbench initdb ..."
  if ! initdb -D "$pgdata" -U postgres --locale=C --encoding=UTF8 -A trust \
    >"$raw" 2>&1; then
    info "  initdb FAILED (see $raw)"
    echo "$failrow" >>"$PG_CSV"
    return 1
  fi

  info "pgbench starting postgres ..."
  # -w with a generous timeout: the server has to fsync its way through
  # startup on storage that may be slow, which is after all the point.
  if ! pg_ctl -D "$pgdata" -l "$RAWDIR/pgbench_${sl}_server.log" -w -t 120 \
    -o "$(pg_conf_args)" start >>"$raw" 2>&1; then
    info "  postgres FAILED to start (see $RAWDIR/pgbench_${sl}_server.log)"
    echo "$failrow" >>"$PG_CSV"
    return 1
  fi
  PG_ACTIVE="$pgdata"

  if ! createdb -h "$PG_SOCKDIR" -U postgres bench >>"$raw" 2>&1; then
    info "  createdb FAILED (see $raw)"
    pg_ctl -D "$pgdata" -m immediate -w stop >/dev/null 2>&1
    PG_ACTIVE=""
    echo "$failrow" >>"$PG_CSV"
    return 1
  fi

  # ---- load ------------------------------------------------------------
  # Bulk write throughput through the database rather than through dd: table
  # heap, index build and the vacuum that follows. pgbench times itself, and
  # its own figure is used rather than a wall clock around it so the number
  # means the same thing as the one pgbench prints.
  info "pgbench load (scale $PGBENCH_SCALE) ..."
  out="$(pgbench -i -s "$PGBENCH_SCALE" -h "$PG_SOCKDIR" -U postgres bench 2>&1)"
  rc=$?
  printf '%s\n' "$out" >>"$raw"
  if [ $rc -ne 0 ]; then
    info "  load FAILED (see $raw)"
    pg_ctl -D "$pgdata" -m immediate -w stop >/dev/null 2>&1
    PG_ACTIVE=""
    echo "$failrow" >>"$PG_CSV"
    return 1
  fi
  init_s="$(printf '%s\n' "$out" | sed -n 's/^done in \([0-9.]*\) s .*/\1/p' | tail -1)"
  [ -z "$init_s" ] && init_s="n/a"
  info "  loaded in ${init_s}s"

  # ---- warmup ----------------------------------------------------------
  # Unlogged and unmeasured, purely to get the cluster out of its cold start:
  # the buffer cache filled, the WAL past its first recycle, and at least one
  # checkpoint behind it. Its output is kept in raw/ so the discarded numbers
  # can still be compared against the measured ones.
  if [ "$PGBENCH_WARMUP" -gt 0 ]; then
    info "pgbench warmup (${PGBENCH_WARMUP}s, not measured) ..."
    printf '\n=== warmup, not measured ===\n' >>"$raw"
    out="$(pgbench -h "$PG_SOCKDIR" -U postgres \
      -c "$PGBENCH_CLIENTS" -j "$PGBENCH_JOBS" -T "$PGBENCH_WARMUP" \
      -M "$PGBENCH_MODE" bench 2>&1)"
    printf '%s\n' "$out" >>"$raw"
    info "  warmed at $(printf '%s\n' "$out" | sed -n 's/^tps = \([0-9.]*\).*/\1/p' | tail -1) tps"
  fi

  # ---- timed run -------------------------------------------------------
  # --log with --aggregate-interval gives one row per interval per thread,
  # which pgbench_series folds back together for the graphs. Without the
  # aggregate it would log every single transaction — millions of lines.
  #
  # --no-vacuum because the warmup has just left the tables in the state a
  # running database is in, and pgbench's default pre-run vacuum would undo
  # exactly that. With no warmup the cluster was freshly loaded and pgbench
  # vacuums as part of the load, so there is nothing for it to do either way.
  #
  # -P prints a progress line to the raw output; on a run measured in minutes
  # it is the only sign it is still alive.
  info "pgbench run (${PGBENCH_CLIENTS} clients, ${PGBENCH_MODE}, ${PGBENCH_TIME}s) ..."
  printf '\n=== measured run ===\n' >>"$raw"
  rm -f "$prefix".*
  out="$(pgbench -h "$PG_SOCKDIR" -U postgres \
    -c "$PGBENCH_CLIENTS" -j "$PGBENCH_JOBS" -T "$PGBENCH_TIME" \
    -M "$PGBENCH_MODE" --no-vacuum -P 10 \
    --log --log-prefix="$prefix" \
    --aggregate-interval="$PGBENCH_AGG_INTERVAL" bench 2>&1)"
  rc=$?
  printf '%s\n' "$out" >>"$raw"

  pg_ctl -D "$pgdata" -m immediate -w stop >/dev/null 2>&1
  PG_ACTIVE=""

  if [ $rc -ne 0 ]; then
    info "  run FAILED (see $raw)"
    echo "$failrow" >>"$PG_CSV"
    rm -rf "$pgdata"
    return 1
  fi

  tps="$(printf '%s\n' "$out" | sed -n 's/^tps = \([0-9.]*\).*/\1/p' | tail -1)"
  lat="$(printf '%s\n' "$out" | sed -n 's/^latency average = \([0-9.]*\) ms.*/\1/p' | tail -1)"
  txns="$(printf '%s\n' "$out" | sed -n 's/^number of transactions actually processed: \([0-9]*\).*/\1/p' | tail -1)"
  failed="$(printf '%s\n' "$out" | sed -n 's/^number of failed transactions: \([0-9]*\).*/\1/p' | tail -1)"
  [ -z "$tps" ] && tps="n/a"
  [ -z "$lat" ] && lat="n/a"
  [ -z "$txns" ] && txns="n/a"
  [ -z "$failed" ] && failed=0

  info "  $tps tps, ${lat}ms mean latency"
  echo "$RUN_ID,$mp,$PGBENCH_SCALE,$PGBENCH_CLIENTS,$PGBENCH_JOBS,$PGBENCH_MODE,$PGBENCH_WARMUP,$PGBENCH_TIME,$init_s,$tps,$lat,$txns,$failed" >>"$PG_CSV"

  # The cluster is ~16 MiB per scale point and the next mount wants the space.
  rm -rf "$pgdata"
}

# ---------------------------------------------------------------------------
# One test against one mount
# ---------------------------------------------------------------------------
run_test() {
  local mp="$1" test="$2"

  case "$test" in

  seq_write_1m)
    run_fio "$mp" seq_write_1m \
      --name=seq_write_1m --filename=fio_seq.dat --rw=write --bs=1M \
      --size="$FIO_SIZE" --numjobs=1 --iodepth=16 --direct=1 \
      --ioengine="$IOENGINE" --runtime="$FIO_RUNTIME" --time_based
    ;;

  # The two jobs dd used to be, and the only two in the suite that differ in
  # what is *in* the buffer rather than in how it is written. Everything else
  # about them matches seq_write_1m, which is what makes the three comparable:
  # a backend that stores what it is given returns the same number three times,
  # and one that compresses or deduplicates does not.
  #
  # --zero_buffers: every block is zeros, so maximally compressible and, being
  # all identical, maximally dedupable. The optimistic bound.
  seq_write_zero_1m)
    run_fio "$mp" seq_write_zero_1m \
      --name=seq_write_zero_1m --filename=fio_seq_zero.dat --rw=write --bs=1M \
      --size="$FIO_SIZE" --numjobs=1 --iodepth=16 --direct=1 \
      --ioengine="$IOENGINE" --runtime="$FIO_RUNTIME" --time_based \
      --zero_buffers
    ;;

  # --refill_buffers: fresh random data for every block, so nothing to compress
  # and no two blocks alike. Note this is not fio's default, which seq_write_1m
  # uses: that fills one buffer at startup and rewrites it, which is
  # incompressible but perfectly dedupable — a third case dd could not express
  # at all. Where dd if=/dev/urandom was mostly measuring how fast the kernel
  # generates randomness, fio's PRNG is fast enough to measure the storage.
  seq_write_rand_1m)
    run_fio "$mp" seq_write_rand_1m \
      --name=seq_write_rand_1m --filename=fio_seq_rand.dat --rw=write --bs=1M \
      --size="$FIO_SIZE" --numjobs=1 --iodepth=16 --direct=1 \
      --ioengine="$IOENGINE" --runtime="$FIO_RUNTIME" --time_based \
      --refill_buffers
    ;;

  seq_read_1m)
    run_fio "$mp" seq_read_1m \
      --name=seq_read_1m --filename=fio_seq.dat --rw=read --bs=1M \
      --size="$FIO_SIZE" --numjobs=1 --iodepth=16 --direct=1 \
      --ioengine="$IOENGINE" --runtime="$FIO_RUNTIME" --time_based
    ;;

  rand_write_4k)
    run_fio "$mp" rand_write_4k \
      --name=rand_write_4k --filename=fio_rand.dat --rw=randwrite --bs=4k \
      --size="$FIO_SIZE" --numjobs=4 --iodepth=32 --direct=1 \
      --ioengine="$IOENGINE" --runtime="$FIO_RUNTIME" --time_based
    ;;

  rand_read_4k)
    run_fio "$mp" rand_read_4k \
      --name=rand_read_4k --filename=fio_rand.dat --rw=randread --bs=4k \
      --size="$FIO_SIZE" --numjobs=4 --iodepth=32 --direct=1 \
      --ioengine="$IOENGINE" --runtime="$FIO_RUNTIME" --time_based
    ;;

  rand_rw_70_30_4k)
    run_fio "$mp" rand_rw_70_30_4k \
      --name=rand_rw_70_30_4k --filename=fio_mix.dat --rw=randrw --rwmixread=70 \
      --bs=4k --size="$FIO_SIZE" --numjobs=4 --iodepth=32 --direct=1 \
      --ioengine="$IOENGINE" --runtime="$FIO_RUNTIME" --time_based
    ;;

  # QD1 with an fsync per write — mimics a database WAL. The most
  # storage-sensitive number here, and the best predictor of real database
  # commit latency.
  fsync_8k_qd1)
    run_fio "$mp" fsync_8k_qd1 \
      --name=fsync_8k_qd1 --filename=fio_sync.dat --rw=randwrite --bs=8k \
      --size=1G --numjobs=1 --iodepth=1 --fsync=1 --direct=1 \
      --ioengine=psync --runtime="$FIO_RUNTIME" --time_based
    ;;

  # Skipped rather than failed when postgres is unavailable — the preflight has
  # already said why, and the rest of the suite is still worth finishing.
  pgbench)
    [ "$have_pgbench" = 1 ] || return 0
    run_pgbench "$mp"
    ;;

  *)
    echo "unknown test: $test" >&2
    return 1
    ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
START_EPOCH=$(date +%s)

RUN_IDS=()

if [ -n "$REPLOT_DIR" ]; then
  # RUN_IDS the way every other pass-specific thing in this script is found:
  # by the directory raw/<pass>/ that a real pass leaves behind, not by
  # replaying REPEATS against fio and pgbench again.
  readarray -t RUN_IDS < <(cd "$OUTDIR/raw" 2>/dev/null && ls -d run-* 2>/dev/null | sort)
  if [ ${#RUN_IDS[@]} -eq 0 ]; then
    echo "No raw/run-* directories under $OUTDIR. Nothing to replot." >&2
    exit 1
  fi
  REPEATS=${#RUN_IDS[@]}
  # Points RAWDIR/LOGDIR/PLOTDATA at the last pass, same as the last iteration
  # of a real run would have left them — nothing after this point reads them
  # for any pass but the last.
  set_run_paths "$REPEATS"
  ELAPSED_LABEL="n/a (this report was rebuilt with --replot; see the original report for the real figure)"
else
  for pass in $(seq 1 "$REPEATS"); do
    set_run_paths "$pass"
    RUN_IDS+=("$RUN_ID")

    if [ "$REPEATS" -gt 1 ]; then
      log "pass $pass of $REPEATS ($RUN_ID)"
      # The same cooldown that separates runs within a pass separates the
      # passes themselves, so pass 2 does not start measuring while the
      # backend is still flushing what pass 1 wrote.
      [ "$pass" -gt 1 ] && settle
    fi

    if [ "$ORDER" = "by-mount" ]; then
      first_mount=1
      for mp in "${USABLE[@]}"; do
        [ $first_mount -eq 0 ] && {
          log "cooldown between mounts"
          settle
        }
        first_mount=0
        log "$mp"
        first_test=1
        for t in "${TESTS[@]}"; do
          # The gap between consecutive tests on one mount. Without it a test
          # begins while the previous one's writeback is still in flight, and
          # that shows up in its first samples as the storage being slower
          # than it is.
          [ $first_test -eq 0 ] && test_settle
          first_test=0
          run_test "$mp" "$t"
        done
      done
    else
      first_unit=1
      for t in "${TESTS[@]}"; do
        log "$t"
        for mp in "${USABLE[@]}"; do
          # by-test already pauses between every (test, mount) unit, and
          # SETTLE is longer than TEST_SETTLE would be, so there is nothing to
          # add here.
          [ $first_unit -eq 0 ] && settle
          first_unit=0
          info "-> $mp"
          run_test "$mp" "$t"
        done
      done
    fi
  done
fi

ELAPSED=$(($(date +%s) - START_EPOCH))
[ -n "$REPLOT_DIR" ] || ELAPSED_LABEL="${ELAPSED}s"

# ---------------------------------------------------------------------------
# Graphs
#
# Every fio log line is:   time_ms, value, ddir, blocksize, offset
# with ddir 0 = read, 1 = write, 2 = trim. One graph per fio test per metric,
# with every mount (and both directions, where the job does both) drawn on the
# same axes so a head-to-head comparison is one glance rather than two files.
#
# The x axis is time *within* that job, not wall clock: each fio run restarts
# at zero, which is what makes runs on different mounts comparable even in
# by-mount order where they are minutes apart.
# ---------------------------------------------------------------------------
DDIR_NAME=(read write)

# Every test but pgbench is an fio job, and has been since dd left.
FIO_TESTS=()
if [ -n "$REPLOT_DIR" ]; then
  # The subset the original run actually used, read from its own CSV rather
  # than from today's FIO_TESTS environment variable — a --replot has no
  # reason to see the same value that env var held when the run happened.
  readarray -t _present < <(tail -n +2 "$FIO_CSV" | awk -F, '{print $3}' | sort -u)
  for t in "${ALL_FIO_TESTS[@]}"; do
    for p in "${_present[@]}"; do
      [ "$t" = "$p" ] && FIO_TESTS+=("$t") && break
    done
  done
  unset _present
else
  for t in "${TESTS[@]}"; do
    case "$t" in
    pgbench) ;;
    *) FIO_TESTS+=("$t") ;;
    esac
  done
fi

# What each fio job is for, in the report's words. Kept next to nothing else on
# purpose: the flags themselves are quoted from FIO_ARGS, which run_fio fills in
# as it runs, so this only has to explain intent and never has to be kept in
# step with the command line.
fio_test_purpose() { # <test>
  case "$1" in
  seq_write_1m)
    cat <<'EOF'
Streaming write bandwidth. One worker pushing 1 MiB blocks with 16 requests in
flight — large enough blocks and deep enough queue that the backend has every
chance to coalesce and pipeline, so this is close to the best sequential number
it can produce. This is the figure that predicts bulk restores, backup writes,
image pulls and log shipping.
EOF
    ;;
  seq_write_zero_1m)
    cat <<'EOF'
`seq_write_1m` again, with `--zero_buffers`: every block written is zeros. That
is the most compressible and the most dedupable data there is, so a backend
doing either inline will beat its own `seq_write_1m` figure here, sometimes by
an order of magnitude, without a byte of it reaching a disk. A backend that
stores what it is given produces the same number twice.

This is one half of what `dd if=/dev/zero` was for. It is the optimistic bound:
no real workload writes only zeros, and any storage vendor's headline
throughput figure that looks like this one is quoting it.
EOF
    ;;
  seq_write_rand_1m)
    cat <<'EOF'
The pessimistic bound, and the other half. `--refill_buffers` makes fio
generate fresh random data for every block, so there is nothing to compress and
no two blocks alike to deduplicate — the backend has to store all of it.

Note that this is not the same as fio's default, which `seq_write_1m` uses:
that fills one buffer with random data at startup and writes *the same buffer*
over and over, which is incompressible but perfectly dedupable. Three jobs,
three answers, and the spread between them is the size of the backend's
data-reduction claim. Where `dd if=/dev/urandom` was mostly measuring how fast
the kernel could generate randomness, fio's PRNG is fast enough that this
measures the storage.
EOF
    ;;
  seq_read_1m)
    cat <<'EOF'
Streaming read bandwidth, reading back the file `seq_write_1m` just wrote. Same
shape as the write test, so the two are directly comparable; a backend that
reads much faster than it writes is usually acknowledging writes to a slower
durable tier, or replicating them.

O_DIRECT, like everything else here, so this is the storage rather than the
page cache — which is what `dd iflag=direct` was checking, and this one cannot
silently fall back to a cached read the way dd did.
EOF
    ;;
  rand_write_4k)
    cat <<'EOF'
Write IOPS under concurrency. Four workers share one file, each with 32 requests
outstanding, so up to 128 4 KiB writes are in flight at once. Blocks this small
and scattered defeat readahead and write coalescing, which is the point: it
measures how many discrete operations the backend can retire per second rather
than how much data it can stream.
EOF
    ;;
  rand_read_4k)
    cat <<'EOF'
Read IOPS under the same concurrency, against the file `rand_write_4k` left
behind. With the page cache bypassed every one of these has to be served by the
backend, so this is the read-side counterpart to the number above.
EOF
    ;;
  rand_rw_70_30_4k)
    cat <<'EOF'
The same random 4 KiB workload with reads and writes interleaved, 70% read to
30% write, which is far closer to what an application actually does than either
pure test. It is also where backends that look fine in isolation come apart:
read-modify-write on parity layouts, and log-structured stores whose compaction
only kicks in once writes are mixed in, both show up here and not above.
EOF
    ;;
  fsync_8k_qd1)
    cat <<'EOF'
Commit latency, and the number that usually separates one storage class from
another. A single worker, one request outstanding, `fsync` after every 8 KiB
write: no concurrency, so nothing can hide the round trip and every write must
be durable before the next one starts. This is what a database WAL does, and
the IOPS figure here is roughly the transaction rate a synchronous commit can
expect. It deliberately uses the blocking `psync` engine and a fixed 1G file
rather than the shared `FIO_SIZE`, because queue depth 1 is the whole point.
EOF
    ;;
  esac
}

# Reduce one fio log to "seconds value" pairs for a single data direction.
# Concurrent jobs each emit their own sample per window (per_job_logs=0 only
# concatenates them), so throughput has to be summed across jobs while latency
# is averaged. Timestamps drift by a millisecond or two between jobs, hence the
# rounding onto the nearest window boundary before grouping.
fio_series() { # <logfile> <ddir> <sum|avg> <scale> <drop_nonpositive>
  local f="$1" ddir="$2" mode="$3" scale="$4" drop="$5"
  [ -s "$f" ] || return 0
  awk -F'[,[:space:]]+' \
    -v ddir="$ddir" -v mode="$mode" -v scale="$scale" \
    -v drop="$drop" -v win="$LOG_AVG_MSEC" '
    $3 == ddir {
      if (drop == 1 && $2 <= 0) next
      b = int(($1 + win / 2) / win) * win
      sum[b] += $2
      n[b]++
    }
    END {
      for (b in sum) {
        v = (mode == "avg" ? sum[b] / n[b] : sum[b]) * scale
        printf "%.3f %.6f\n", b / 1000, v
      }
    }' "$f" | sort -n
}

# Reduce pgbench's aggregate logs to "seconds value" pairs. Every worker thread
# writes its own file — <prefix>.<pid> for the first and <prefix>.<pid>.<n> for
# the rest — so the rows for one interval have to be combined across them:
# transactions summed, mean latency weighted by transaction count, worst-case
# latency taken as the worst any thread saw.
#
# Latencies in the log are microseconds. Interval timestamps are absolute Unix
# seconds, so they are rebased onto the start of the run to match the fio
# graphs, whose x axis is also elapsed-within-the-run.
pgbench_series() { # <log prefix> <tps|lat|maxlat>
  local prefix="$1" mode="$2"
  local files=()
  local f
  for f in "$prefix".*; do [ -f "$f" ] && files+=("$f"); done
  [ ${#files[@]} -eq 0 ] && return 0

  awk -v mode="$mode" -v ivl="$PGBENCH_AGG_INTERVAL" '
    {
      t = $1
      tx[t] += $2
      lat[t] += $3
      if ($6 + 0 > mx[t]) mx[t] = $6 + 0
      if (lo == "" || t < lo) lo = t
      if (hi == "" || t > hi) hi = t
    }
    END {
      n = 0
      for (t in tx) n++
      # The first and last intervals are partial — the run started and stopped
      # partway through a second — so both read as a dip that is an artefact of
      # the clock rather than the storage. Dropped, unless the run was so short
      # that dropping them would leave nothing.
      trim = (n >= 3)
      for (t in tx) {
        if (trim && (t == lo || t == hi)) continue
        if (tx[t] <= 0) continue
        if (mode == "tps") v = tx[t] / ivl
        else if (mode == "lat") v = lat[t] / tx[t] / 1000
        else v = mx[t] / 1000
        printf "%.3f %.6f\n", t - lo, v
      }
    }' "${files[@]}" | sort -n
}

# Draws one series onto a chart being built up in the caller's `parts` array,
# as a tab-separated spec render_plot later splits into a per-series line in
# render-chart.awk's META file: <datfile> <style> <colour index> <dash index>
# <title>. style is band|dash|line — see render-chart.awk's header comment.
plot_part() { # <datfile> <title> <band|dash|line> <colour index> [dash index]
  printf '%s\t%s\t%s\t%s\t%s' "$1" "$3" "$4" "${5:-0}" "$2"
}

# One SVG for one chart, shared by the fio and pgbench plots so there is one
# place where the axes, the legend and the interactivity are decided. Draws
# with render-chart.awk rather than gnuplot: the graphs need to overlay a few
# series of a few hundred samples each, which is comfortably inside plain
# awk, and drawing them there means a hover tooltip — nearest-sample lookup
# baked into a small embedded <script>, since a plot of this many points is a
# poor fit for a `<title>` per point — instead of a static image, at no extra
# runtime dependency: awk is already load-bearing for everything else this
# script parses. Returns non-zero if given nothing.
render_plot() { # <img> <title> <xlabel> <ylabel> <logscale> <part>...
  local img="$1" desc="$2" xlabel="$3" ylabel="$4" logscale="$5"
  shift 5
  local parts=("$@")

  [ ${#parts[@]} -eq 0 ] && return 1

  # META pairs each data file with how to draw it. It sits right next to the
  # SVG it drew, named to match, so the chart can be redrawn by hand:
  #   awk -v META=foo.meta -v TITLE=... -f graphs/render-chart.awk *.dat
  local meta="${img%.svg}.meta" datfiles=() p dat style ci di title
  : >"$meta"
  for p in "${parts[@]}"; do
    IFS=$'\t' read -r dat style ci di title <<<"$p"
    datfiles+=("$dat")
    printf '%s\t%s\t%s\t%s\n' "$style" "$ci" "$di" "$title" >>"$meta"
  done

  # Every chart's ids are prefixed with a slug of its own path, so a report
  # page that inlines dozens of these side by side — which it does, because a
  # <script> inside an <img src="data:.."> never executes — never has one
  # chart's ids collide with another's.
  local uid
  uid="$(slug "${img#"$PLOTDIR"/}")"
  uid="${uid//[.\/]/-}"

  awk -v META="$meta" -v TITLE="$desc" -v XLABEL="$xlabel" -v YLABEL="$ylabel" \
    -v LOGSCALE="$logscale" -v UID="$uid" \
    -f "$RENDER_AWK" "${datfiles[@]}" >"$img" 2>>"$PLOTDIR/render.log"
  local rc=$?

  [ $rc -eq 0 ] && [ -s "$img" ]
}

# Fold the same series from every pass into one "time mean min max" file. The
# passes share a time base — each series is already rebased onto the start of
# its own run — so the buckets line up and can simply be averaged across files.
#
# A bucket at the very end may exist in only some passes, if one run produced a
# sample a fraction of a window later than the others. Averaging over however
# many passes actually reached that bucket is the honest answer; the band there
# collapses onto the line, which is the correct picture of a single sample.
aggregate_series() { # <dat>...
  awk '
    {
      s[$1] += $2
      n[$1]++
      if (!($1 in mn) || $2 < mn[$1]) mn[$1] = $2
      if (!($1 in mx) || $2 > mx[$1]) mx[$1] = $2
    }
    END {
      for (t in s) printf "%.3f %.6f %.6f %.6f\n", t, s[t] / n[t], mn[t], mx[t]
    }' "$@" | sort -n
}

# One SVG for one (test, metric), overlaying every mount and direction that
# produced samples. Returns non-zero if there was nothing to draw.
#
# With `agg` as the pass id it plots the mean across passes with the min-max
# spread shaded behind it, reading the per-pass .dat files that the earlier
# calls left behind; otherwise it plots that one pass.
plot_metric() { # <pass id> <test> <log-suffix> <key> <sum|avg> <scale> <ylabel> <title> <logscale>
  local rid="$1" test="$2" suffix="$3" key="$4" mode="$5" scale="$6"
  local ylabel="$7" desc="$8" logscale="$9"
  local parts=() mp sl d dat title ci=0 srcs outdir logdir datdir style=line
  [ "$rid" = agg ] && style=band

  # Derived from the pass being drawn, not read from the LOGDIR/PLOTDATA
  # globals: by the time the graphs are drawn those still point at whichever
  # pass ran last, so every pass would silently be plotted from the last one's
  # logs and the aggregate would average one pass with itself.
  if [ "$rid" = agg ]; then outdir="$PLOTDIR/aggregate"; else outdir="$PLOTDIR/$rid"; fi
  logdir="$OUTDIR/fio-logs/$rid"
  datdir="$PLOTDIR/data/$rid"
  mkdir -p "$outdir" "$datdir"

  for mp in "${USABLE[@]}"; do
    sl="$(slug "$mp")"
    for d in 0 1; do
      title="${DDIR_NAME[$d]}"
      [ ${#USABLE[@]} -gt 1 ] && title="$mp ${DDIR_NAME[$d]}"

      if [ "$rid" = agg ]; then
        srcs=()
        for r in "${RUN_IDS[@]}"; do
          [ -s "$PLOTDIR/data/$r/${sl}_${test}_${key}_${DDIR_NAME[$d]}.dat" ] &&
            srcs+=("$PLOTDIR/data/$r/${sl}_${test}_${key}_${DDIR_NAME[$d]}.dat")
        done
        [ ${#srcs[@]} -eq 0 ] && continue
        dat="$PLOTDIR/data/aggregate_${sl}_${test}_${key}_${DDIR_NAME[$d]}.dat"
        aggregate_series "${srcs[@]}" >"$dat"
      else
        dat="$datdir/${sl}_${test}_${key}_${DDIR_NAME[$d]}.dat"
        # logscale doubles as the drop-non-positive flag: a zero is a real datum
        # on a throughput plot (the backend stalled) and must stay, but it has no
        # place on a log axis, where gnuplot would silently drop it anyway.
        fio_series "$logdir/${sl}_${test}${suffix}" "$d" "$mode" "$scale" "$logscale" >"$dat"
      fi

      if [ ! -s "$dat" ]; then
        rm -f "$dat"
        continue
      fi
      parts+=("$(plot_part "$dat" "$title" "$style" "$ci")")
      ci=$((ci + 1))
    done
  done

  render_plot "$outdir/${test}_${key}.svg" \
    "$desc - $test" "elapsed within the fio run (s)" "$ylabel" "$logscale" \
    "${parts[@]}"
}

# The pgbench counterpart: one metric, every mount on the same axes. There is
# no read/write split here — a TPC-B transaction is both.
plot_pgbench() { # <pass id> <key> <tps|lat|maxlat> <ylabel> <title> <logscale>
  local rid="$1" key="$2" mode="$3" ylabel="$4" desc="$5" logscale="$6"
  local parts=() mp sl dat title ci=0 srcs outdir logdir datdir style=line
  [ "$rid" = agg ] && style=band

  # Same reason as plot_metric: the pass being drawn, not whichever ran last.
  if [ "$rid" = agg ]; then outdir="$PLOTDIR/aggregate"; else outdir="$PLOTDIR/$rid"; fi
  logdir="$OUTDIR/fio-logs/$rid"
  datdir="$PLOTDIR/data/$rid"
  mkdir -p "$outdir" "$datdir"

  for mp in "${USABLE[@]}"; do
    sl="$(slug "$mp")"
    title="pgbench"
    [ ${#USABLE[@]} -gt 1 ] && title="$mp"

    if [ "$rid" = agg ]; then
      srcs=()
      for r in "${RUN_IDS[@]}"; do
        [ -s "$PLOTDIR/data/$r/${sl}_pgbench_${key}.dat" ] &&
          srcs+=("$PLOTDIR/data/$r/${sl}_pgbench_${key}.dat")
      done
      [ ${#srcs[@]} -eq 0 ] && continue
      dat="$PLOTDIR/data/aggregate_${sl}_pgbench_${key}.dat"
      aggregate_series "${srcs[@]}" >"$dat"
    else
      dat="$datdir/${sl}_pgbench_${key}.dat"
      pgbench_series "$logdir/pgbench_${sl}" "$mode" >"$dat"
    fi

    if [ ! -s "$dat" ]; then
      rm -f "$dat"
      continue
    fi
    parts+=("$(plot_part "$dat" "$title" "$style" "$ci")")
    ci=$((ci + 1))
  done

  render_plot "$outdir/pgbench_${key}.svg" \
    "$desc - pgbench" "elapsed within the pgbench run (s)" "$ylabel" "$logscale" \
    "${parts[@]}"
}

# Every pass on one set of axes, unaggregated. The aggregate answers "what does
# this storage do"; this answers "did it do the same thing every time", and
# unlike the band it names the pass that disagreed — a first pass that was slow
# because a cache was cold looks nothing like one pass in three stalling at
# random, and the band renders both as the same width.
#
# Reads the per-pass .dat files the pass loop already wrote, so it has to run
# after them.
plot_compare() { # <base> <key> <ylabel> <title> <logscale>
  local base="$1" key="$2" ylabel="$3" desc="$4" logscale="$5"
  local parts=() mp sl d r dat title ci=0 di drew xlabel
  local outdir="$PLOTDIR/compare"
  mkdir -p "$outdir"

  local dirs=(0 1)
  xlabel="elapsed within the fio run (s)"
  if [ "$base" = pgbench ]; then
    dirs=(-)
    xlabel="elapsed within the pgbench run (s)"
  fi

  for mp in "${USABLE[@]}"; do
    sl="$(slug "$mp")"
    for d in "${dirs[@]}"; do
      di=0
      drew=0
      for r in "${RUN_IDS[@]}"; do
        if [ "$base" = pgbench ]; then
          dat="$PLOTDIR/data/$r/${sl}_pgbench_${key}.dat"
          title="$r"
        else
          dat="$PLOTDIR/data/$r/${sl}_${base}_${key}_${DDIR_NAME[$d]}.dat"
          title="$r ${DDIR_NAME[$d]}"
        fi
        [ ${#USABLE[@]} -gt 1 ] && title="$title $mp"

        # The dash index still advances for a pass that produced nothing, so a
        # pass keeps the same dash pattern in every chart it appears in.
        if [ -s "$dat" ]; then
          parts+=("$(plot_part "$dat" "$title" dash "$ci" "$di")")
          drew=1
        fi
        di=$((di + 1))
      done
      # Only a series that drew something consumes a colour, so the colours stay
      # dense rather than leaving gaps for write-only tests.
      [ $drew -eq 1 ] && ci=$((ci + 1))
    done
  done

  render_plot "$outdir/${base}_${key}.svg" \
    "$desc - $base, every pass" "$xlabel" "$ylabel" "$logscale" "${parts[@]}"
}

pgbench_graphed=0
cmp_graphed=0
agg_graphed=0

if [ "$have_plot" = 1 ]; then
  log "Drawing graphs"

  # Materialised once per run rather than shipped as its own file: the image
  # is deliberately one script (see default.nix), and this keeps it that way
  # while still leaving a real, standalone .awk file under graphs/ that the
  # report can point people at to redraw a chart by hand.
  RENDER_AWK="$PLOTDIR/render-chart.awk"
  cat >"$RENDER_AWK" <<'AWKEOF'
#!/usr/bin/awk -f
# render-chart.awk — draws one interactive SVG line/band chart from the
# reduced "time value" series storage-bench.sh's fio_series/pgbench_series
# leave behind, in the same spirit as storage-chaos.sh's hand-rolled charts:
# no gnuplot, no rasteriser, nothing but awk and the browser's own SVG
# renderer.
#
# gnuplot's static SVG terminal cannot answer on hover, and a plain per-point
# <title> (which is all storage-chaos needs, for its couple of dozen discrete
# events) does not suit a few hundred samples on a line — so this bakes the
# series into a small embedded <script> that finds the nearest sample under
# the cursor and draws a crosshair + tooltip. No network fetch, no external
# library.
#
# Invocation:
#   awk -v META=<meta-file> -v TITLE=.. -v XLABEL=.. -v YLABEL=.. \
#       -v LOGSCALE=0|1 -v UID=<chart-unique-id-prefix> \
#       -f render-chart.awk file1.dat file2.dat ... > out.svg
#
# META has one tab-separated line per data file, in the same order:
#   style<TAB>colour-index<TAB>dash-index<TAB>title
# style is one of:
#   band   file has 4 columns "t mean min max" — a shaded min-max band with
#          the mean drawn over it (what REPEATS>1 aggregates use)
#   line   file has 2 columns "t v" — a plain solid line (one pass, no band)
#   dash   file has 2 columns "t v" — a dashed line, dash pattern by
#          dash-index (what the "every pass on one axis" compare charts use)
#
# UID prefixes every element id this chart defines, so a report page that
# inlines many of these charts side by side (which it does, precisely so the
# embedded <script> tags run at all — a script inside an <img src="data:..">
# does not execute) never has one chart's ids collide with another's.

function esc(s) {
  gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
  return s
}

# Escapes for a double-quoted JS string literal embedded inside the <script>.
function jsesc(s) {
  gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
  gsub(/\n/, " ", s)
  return s
}

# Tick spacing and time labels, straight out of storage-chaos.sh's AWK_NICE —
# same round 1/2/5x10^n steps, same "past 90s, switch to minutes" rule, so a
# long fio run reads the same way a long chaos run does instead of one being
# "612.0" seconds while the other says "10m".
function nice_step(range, want,   raw, mag, r) {
  raw = range / want
  if (raw <= 0) return 1
  mag = 1
  while (mag > raw) mag /= 10
  while (mag * 10 <= raw) mag *= 10
  r = raw / mag
  return (r <= 1 ? 1 : (r <= 2 ? 2 : (r <= 5 ? 5 : 10))) * mag
}
# Decimals appropriate to a step: 0.1 wants one, 5 wants none. Past 1000 this
# hands off to the same SI-suffix formatter the log axis already uses (si(),
# defined below) — a fast backend's IOPS axis is otherwise six bare digits
# per tick, which is exactly the illegible-raw-number problem nice_step/hms
# already fixed for elapsed time.
function fmt(v, step,   a) {
  a = (v < 0 ? -v : v)
  if (a >= 1000) return si(v)
  return (step >= 1 ? sprintf("%d", v + 0.0001) :
         (step >= 0.1 ? sprintf("%.1f", v) : sprintf("%.2f", v)))
}
function hms(t) { return (t >= 90 ? sprintf("%dm", int(t / 60)) : sprintf("%ds", int(t))) }

# gnuplot's own default line colours — kept so a chart drawn today still
# looks like one drawn yesterday. Distinguishable in both light and dark.
function color(ci,   c) {
  c = ci % 6
  if (c == 0) return "#9400d3"
  if (c == 1) return "#009e73"
  if (c == 2) return "#56b4e9"
  if (c == 3) return "#e69f00"
  if (c == 4) return "#0072b2"
  return "#e51e10"
}

# gnuplot's own dashtypes: 1 solid, 2 dashed, 3 dotted, 4 dash-dot, 5
# dash-dot-dot. di 0 here is deliberately the first *non-solid* pattern —
# style "dash" is only ever used to tell passes apart on a chart that already
# has one solid "line"/"band" series per colour elsewhere, so a dashed series
# starting at "solid" would be indistinguishable from a line one.
function dasharray(di,   d) {
  d = di % 5
  if (d == 0) return "6 3"
  if (d == 1) return "2 2"
  if (d == 2) return "1 3"
  if (d == 3) return "8 2 2 2"
  return "8 2 1 2 1 2"
}

function id(s) { return UID "-" s }

BEGIN {
  if (LOGSCALE == "") LOGSCALE = 0
  if (UID == "") UID = "c"

  nfiles = 0
  while ((getline mline < META) > 0) {
    nfiles++
    split(mline, mf, "\t")
    mstyle[nfiles] = mf[1]; mci[nfiles] = mf[2] + 0
    mdi[nfiles] = mf[3] + 0; mtitle[nfiles] = mf[4]
  }
  close(META)
}

FNR == 1 { curf++ }

{
  n = npts[curf] + 1
  npts[curf] = n
  t[curf, n] = $1 + 0
  if (mstyle[curf] == "band") {
    mean[curf, n] = $2 + 0; lo[curf, n] = $3 + 0; hi[curf, n] = $4 + 0
    yv1 = lo[curf, n]; yv2 = hi[curf, n]
  } else {
    v[curf, n] = $2 + 0
    yv1 = v[curf, n]; yv2 = yv1
  }
  if (!xseen || $1 + 0 > xmax) { xmax = $1 + 0; xseen = 1 }
  if (!yseen || yv2 > ymax) { ymax = yv2; yseen = 1 }
  if (!yminseen || yv1 < ymin) { ymin = yv1; yminseen = 1 }
}

END {
  if (curf == 0 || nfiles == 0) {
    print "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"></svg>"
    exit
  }

  W = 1100; L = 76; R = 30
  TOP = 40; PLOTH = 340; XAXISH = 44
  LEGROWH = 18
  LEGH = 12 + LEGROWH * nfiles + 8
  H = TOP + PLOTH + XAXISH + LEGH
  X = W - R
  PB = TOP + PLOTH # plot bottom

  xmin = 0
  if (xmax <= xmin) xmax = xmin + 1
  xr = xmax - xmin

  if (LOGSCALE == 1) {
    if (ymin <= 0) ymin = 1e-9
    lymin = log(ymin) / log(10); lymax = log(ymax) / log(10)
    if (lymax <= lymin) lymax = lymin + 1
  } else {
    ymin = 0
    if (ymax <= 0) ymax = 1
    yr = ymax - ymin
  }

  printf "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 %d %d\" width=\"100%%\" font-family=\"system-ui, sans-serif\" font-size=\"12\">\n", W, H
  printf "<rect x=\"0\" y=\"0\" width=\"%d\" height=\"%d\" fill=\"#ffffff\"/>\n", W, H
  printf "<style>#%s .xhair{stroke:#9a9892;stroke-width:1;display:none} #%s .tip{display:none}</style>\n", UID, UID
  printf "<g id=\"%s\">\n", UID
  printf "<text x=\"%d\" y=\"22\" text-anchor=\"middle\" font-size=\"14\" font-weight=\"600\" fill=\"#1c1b1a\">%s</text>\n", W / 2, esc(TITLE)
  printf "<text x=\"%d\" y=\"%d\" text-anchor=\"middle\" fill=\"#52514e\">%s</text>\n", L + (X - L) / 2, PB + XAXISH - 6, esc(XLABEL)
  printf "<text x=\"16\" y=\"%d\" text-anchor=\"middle\" fill=\"#52514e\" transform=\"rotate(-90 16 %d)\">%s</text>\n", TOP + PLOTH / 2, TOP + PLOTH / 2, esc(YLABEL)

  # y gridlines
  if (LOGSCALE == 1) {
    e0 = int(lymin); if (e0 > lymin) e0--
    e1 = int(lymax); if (e1 < lymax) e1++
    step = 1
    if (e1 - e0 > 6) step = int((e1 - e0 + 5) / 6)
    for (e = e0; e <= e1; e += step) {
      yv = e
      if (yv < lymin || yv > lymax) continue
      py = PB - PLOTH * (yv - lymin) / (lymax - lymin)
      printf "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"#e5e4e0\"/>\n", L, py, X, py
      printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" fill=\"#52514e\">%s</text>\n", L - 8, py + 4, si(exp(e * log(10)))
    }
  } else {
    ystep = nice_step(yr, 5)
    for (yv = 0; yv <= ymax + ystep / 1000; yv += ystep) {
      py = PB - PLOTH * (yv - ymin) / yr
      printf "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"#e5e4e0\"/>\n", L, py, X, py
      printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" fill=\"#52514e\">%s</text>\n", L - 8, py + 4, fmt(yv, ystep)
    }
  }

  # x gridlines — same round steps and the same seconds/minutes switch as
  # storage-chaos.sh's timeline, so the two reports read the same way.
  xstep = nice_step(xr, 6)
  for (xv = 0; xv <= xmax + xstep / 1000; xv += xstep) {
    px = L + (X - L) * (xv - xmin) / xr
    printf "<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%d\" stroke=\"#e5e4e0\"/>\n", px, TOP, px, PB
    printf "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\" fill=\"#52514e\">%s</text>\n", px, PB + 18, hms(xv)
  }

  printf "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" fill=\"none\" stroke=\"#c8c6c0\"/>\n", L, TOP, X - L, PLOTH

  # series
  jsdata = ""
  for (f = 1; f <= nfiles; f++) {
    c = color(mci[f])
    if (mstyle[f] == "band") {
      poly = ""
      for (p = 1; p <= npts[f]; p++) poly = poly sprintf("%.1f,%.1f ", px_of(t[f, p]), py_of(hi[f, p]))
      for (p = npts[f]; p >= 1; p--) poly = poly sprintf("%.1f,%.1f ", px_of(t[f, p]), py_of(lo[f, p]))
      printf "<polygon points=\"%s\" fill=\"%s\" fill-opacity=\"0.16\" stroke=\"none\"/>\n", poly, c
      line = ""
      for (p = 1; p <= npts[f]; p++) line = line sprintf("%.1f,%.1f ", px_of(t[f, p]), py_of(mean[f, p]))
      printf "<polyline points=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"2\"/>\n", line, c
      jsdata = jsdata "{\"c\":\"" c "\",\"t\":\"" jsesc(mtitle[f]) "\",\"band\":1,\"p\":["
      for (p = 1; p <= npts[f]; p++)
        jsdata = jsdata sprintf("[%.3f,%.6f,%.6f,%.6f],", t[f, p], mean[f, p], lo[f, p], hi[f, p])
      jsdata = jsdata "]},"
    } else {
      line = ""
      for (p = 1; p <= npts[f]; p++) line = line sprintf("%.1f,%.1f ", px_of(t[f, p]), py_of(v[f, p]))
      da = (mstyle[f] == "dash") ? " stroke-dasharray=\"" dasharray(mdi[f]) "\"" : ""
      printf "<polyline points=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"%s\"%s/>\n", \
        line, c, (mstyle[f] == "dash" ? "1.5" : "2"), da
      jsdata = jsdata "{\"c\":\"" c "\",\"t\":\"" jsesc(mtitle[f]) "\",\"band\":0,\"p\":["
      for (p = 1; p <= npts[f]; p++) jsdata = jsdata sprintf("[%.3f,%.6f],", t[f, p], v[f, p])
      jsdata = jsdata "]},"
    }
  }
  sub(/,$/, "", jsdata)

  # legend, one row per series, below the plot rather than beside it — a
  # legend to the right sizes its reserved column by the widest label, and the
  # labels are mount paths; below, a long one costs a line, not a third of the
  # canvas.
  ly = PB + XAXISH + 8
  for (f = 1; f <= nfiles; f++) {
    c = color(mci[f])
    row = ly + (f - 1) * LEGROWH
    if (mstyle[f] == "dash")
      printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"%s\" stroke-width=\"2\" stroke-dasharray=\"%s\"/>\n", \
        L, row - 4, L + 16, row - 4, c, dasharray(mdi[f])
    else
      printf "<rect x=\"%d\" y=\"%d\" width=\"16\" height=\"3\" fill=\"%s\"/>\n", L, row - 6, c
    printf "<text x=\"%d\" y=\"%d\" fill=\"#3a3937\">%s</text>\n", L + 22, row, esc(mtitle[f])
  }

  # crosshair + tooltip, driven by the embedded script below
  printf "<line class=\"xhair\" id=\"%s\" x1=\"0\" y1=\"%d\" x2=\"0\" y2=\"%d\"/>\n", id("xh"), TOP, PB
  printf "<g class=\"tip\" id=\"%s\"><rect id=\"%s\" width=\"10\" height=\"10\" rx=\"4\" fill=\"#1c1b1a\" fill-opacity=\"0.92\"/><text id=\"%s\" x=\"8\" y=\"16\" fill=\"#fcfcfb\" font-size=\"11\"></text></g>\n", \
    id("tip"), id("tipr"), id("tipt")
  printf "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" fill=\"transparent\" id=\"%s\"/>\n", L, TOP, X - L, PLOTH, id("hit")
  print "</g>"

  printf "<script><![CDATA[\n"
  printf "(function(){\n"
  printf "var root=document.getElementById(%s);if(!root)return;\n", jq(UID)
  printf "var svg=root.closest('svg');\n"
  printf "var S=[%s];\n", jsdata
  printf "var L=%d,X=%d,TOP=%d,PB=%d,xmin=%.6f,xr=%.6f;\n", L, X, TOP, PB, xmin, xr
  printf "var hit=root.querySelector('#%s'),xh=root.querySelector('#%s'),tip=root.querySelector('#%s'),tt=root.querySelector('#%s'),tr=root.querySelector('#%s');\n", \
    id("hit"), id("xh"), id("tip"), id("tipt"), id("tipr")
  print "function nearest(pts,tt2){var lo=0,hi=pts.length-1;if(hi<0)return -1;while(hi-lo>1){var m=(lo+hi)>>1;if(pts[m][0]<tt2)lo=m;else hi=m;}return Math.abs(pts[lo][0]-tt2)<Math.abs(pts[hi][0]-tt2)?lo:hi;}"
  print "hit.addEventListener('mousemove',function(ev){"
  print "  var r=svg.getBoundingClientRect();var scale=svg.viewBox.baseVal.width/r.width;"
  print "  var px=(ev.clientX-r.left)*scale;"
  print "  var tval=xmin+xr*(px-L)/(X-L);if(tval<xmin)tval=xmin;if(tval>xmin+xr)tval=xmin+xr;"
  print "  var lines=[{c:'#9a9892',txt:'+'+hms_exact(tval)}];"
  print "  for(var i=0;i<S.length;i++){var s=S[i];var j=nearest(s.p,tval);if(j<0)continue;var d=s.p[j];"
  print "    var txt=s.t+': '+fmtv(d[1]);if(s.band)txt+=' ['+fmtv(d[2])+'-'+fmtv(d[3])+']';"
  print "    lines.push({c:s.c,txt:txt});}"
  print "  if(lines.length<=1)return;"
  print "  xh.style.display='block';xh.setAttribute('x1',px);xh.setAttribute('x2',px);"
  print "  while(tt.firstChild)tt.removeChild(tt.firstChild);"
  print "  var w=90;"
  print "  for(var k=0;k<lines.length;k++){"
  print "    var tsp=document.createElementNS('http://www.w3.org/2000/svg','tspan');"
  print "    tsp.setAttribute('x','20');tsp.setAttribute('y',16+k*15);tsp.textContent=lines[k].txt;"
  print "    if(lines[k].txt.length*6+26>w)w=lines[k].txt.length*6+26;"
  print "    tt.appendChild(tsp);"
  print "    var sw=document.createElementNS('http://www.w3.org/2000/svg','rect');"
  print "    sw.setAttribute('x',8);sw.setAttribute('y',8+k*15);sw.setAttribute('width',8);sw.setAttribute('height',8);sw.setAttribute('fill',lines[k].c);"
  print "    tt.appendChild(sw);"
  print "  }"
  print "  var th=10+lines.length*15+6;tr.setAttribute('width',w);tr.setAttribute('height',th);"
  print "  var tx=Math.min(px+10,X-w-2),ty=TOP+6;"
  print "  tip.setAttribute('transform','translate('+tx+','+ty+')');tip.style.display='block';"
  print "});"
  print "hit.addEventListener('mouseleave',function(){xh.style.display='none';tip.style.display='none';});"
  # Exact, unlike the axis — same split as the time hover: the axis rounds
  # for readability (nice_step/hms, si() past 1000), the hover is what you
  # asked for by pointing at it. Thousands get a separator rather than an SI
  # suffix so it stays exact instead of rounding to '1.9M'.
  print "function fmtv(v){var a=Math.abs(v);var s=a>=1000?v.toFixed(0):(a>=10?v.toFixed(1):v.toFixed(2));"
  print "  var neg=s.charAt(0)==='-';if(neg)s=s.slice(1);var p=s.split('.');"
  print "  p[0]=p[0].replace(/\\B(?=(\\d{3})+(?!\\d))/g,',');return (neg?'-':'')+p.join('.');}"
  # The axis ticks round to whole minutes past 90s, same as storage-chaos.sh's
  # hms() — but a hover is a request for precision the rounded axis gave up,
  # same as chaos's own tooltips (\"killed at +45s\", never \"+1m\"), so this
  # keeps the sub-second reading intact instead of re-rounding it.
  print "function hms_exact(t){if(t<90)return t.toFixed(1)+'s';var m=Math.floor(t/60);return m+'m '+(t-m*60).toFixed(1)+'s';}"
  print "})();"
  printf "]]></script>\n"
  print "</svg>"
}

function jq(s) { return "\"" s "\"" }

function px_of(tv) { return L + (X - L) * (tv - xmin) / xr }

function py_of(yv) {
  if (LOGSCALE == 1) {
    if (yv <= 0) yv = ymin
    return PB - PLOTH * (log(yv) / log(10) - lymin) / (lymax - lymin)
  }
  return PB - PLOTH * (yv - ymin) / yr
}

# SI-suffixed tick label for the log axis: gnuplot's `set format y '%.0s%c'`.
function si(v,   av, u, i) {
  av = v; i = 0
  while (av >= 1000 && i < 4) { av /= 1000; i++ }
  u = (i == 0 ? "" : (i == 1 ? "k" : (i == 2 ? "M" : (i == 3 ? "G" : "T"))))
  if (av == int(av)) return sprintf("%d%s", av, u)
  return sprintf("%.1f%s", av, u)
}
AWKEOF

  # Per pass first, then the aggregate, which reads the per-pass data files the
  # first loop wrote. With REPEATS=1 the aggregate would be the same chart drawn
  # a second time, so it is skipped.
  passes=("${RUN_IDS[@]}")
  [ "$REPEATS" -gt 1 ] && passes+=(agg)

  for rid in "${passes[@]}"; do
    [ "$REPEATS" -gt 1 ] && {
      if [ "$rid" = agg ]; then info "aggregate:"; else info "$rid:"; fi
    }
    for t in "${FIO_TESTS[@]}"; do
      drawn=0
      # bandwidth is logged in KiB/s; 1/1024 puts it in MiB/s.
      # clat is logged in nanoseconds; 1/1000 puts it in microseconds.
      plot_metric "$rid" "$t" _iops.log iops sum 1 "IOPS" "IOPS over time" 0 && drawn=1
      plot_metric "$rid" "$t" _bw.log bw sum 0.0009765625 "bandwidth (MiB/s)" \
        "Bandwidth over time" 0 && drawn=1
      plot_metric "$rid" "$t" _clat.log clat avg 0.001 "completion latency (us)" \
        "Completion latency over time" 1 && drawn=1
      if [ $drawn -eq 1 ]; then info "  $t"; else info "  $t — no samples, skipped"; fi
      [ "$rid" = agg ] && [ $drawn -eq 1 ] && agg_graphed=1
    done

    [ "$have_pgbench" = 1 ] || continue
    drawn=0
    plot_pgbench "$rid" tps tps "transactions/s" "Transaction rate over time" 0 && drawn=1
    plot_pgbench "$rid" lat lat "mean latency (ms)" \
      "Mean transaction latency over time" 1 && drawn=1
    # Worst case rather than mean, because the mean hides exactly what storage
    # does to a database: a checkpoint or an fsync stall shows up as one
    # interval where the slowest transaction took a hundred times the average.
    plot_pgbench "$rid" maxlat maxlat "worst latency (ms)" \
      "Worst transaction latency over time" 1 && drawn=1
    [ $drawn -eq 1 ] && pgbench_graphed=1
    [ "$rid" = agg ] && [ $drawn -eq 1 ] && agg_graphed=1
    if [ $drawn -eq 1 ]; then info "  pgbench"; else info "  pgbench — no samples, skipped"; fi
  done

  # Last, because it reads what every pass above wrote.
  if [ "$REPEATS" -gt 1 ]; then
    info "every pass on one axis:"
    for t in "${FIO_TESTS[@]}"; do
      drawn=0
      plot_compare "$t" iops "IOPS" "IOPS over time" 0 && drawn=1
      plot_compare "$t" bw "bandwidth (MiB/s)" "Bandwidth over time" 0 && drawn=1
      plot_compare "$t" clat "completion latency (us)" \
        "Completion latency over time" 1 && drawn=1
      [ $drawn -eq 1 ] && cmp_graphed=1
      if [ $drawn -eq 1 ]; then info "  $t"; else info "  $t — no samples, skipped"; fi
    done

    if [ "$have_pgbench" = 1 ]; then
      drawn=0
      plot_compare pgbench tps "transactions/s" "Transaction rate over time" 0 && drawn=1
      plot_compare pgbench lat "mean latency (ms)" \
        "Mean transaction latency over time" 1 && drawn=1
      plot_compare pgbench maxlat "worst latency (ms)" \
        "Worst transaction latency over time" 1 && drawn=1
      [ $drawn -eq 1 ] && cmp_graphed=1
      if [ $drawn -eq 1 ]; then info "  pgbench"; else info "  pgbench — no samples, skipped"; fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Markdown report
#
# GitHub-Flavoured Markdown, which means the report is readable as-is in a
# terminal, a pull request or an issue comment without being rendered at all —
# the reason it is Markdown rather than AsciiDoc.
#
# The cost of that trade is paid here: Markdown has no `include::`, so the CSVs
# have to be turned into tables by hand rather than referenced, and it has no
# section numbering, table of contents, anchors or captions, all of which
# render_html adds afterwards. Both files stay in the results directory — the
# CSVs are still the machine-readable copy, the table below is the human one.
# ---------------------------------------------------------------------------

# A header-row CSV as a GFM table. The fields are plain — no quoting, no
# embedded commas, because everything written to these CSVs is a number, a
# mount path or the word FAILED — so splitting on commas is enough. Pipes are
# escaped anyway, since a pipe is the one character that would silently split a
# cell in two.
csv_table() { # <csvfile>
  awk -F, '
    function row(  i, s) {
      s = ""
      for (i = 1; i <= NF; i++) {
        gsub(/\|/, "\\|", $i)
        s = s "| " $i " "
      }
      return s "|"
    }
    NR == 1 {
      print row()
      s = ""
      for (i = 1; i <= NF; i++) s = s "| --- "
      print s "|"
      next
    }
    { print row() }
  ' "$1"
}

# Which set of charts belongs next to the prose. With more than one pass that
# is the aggregate — the mean is the summary you want beside the explanation,
# and the individual passes are detail that goes at the end. With one pass there
# is no aggregate and the one pass is itself the headline.
HEADLINE_GRAPHS=""
HEADLINE_SUFFIX=""
HEADLINE_GRAPH_NOTE=""

# Whether a pass actually produced charts. RUN_IDS has an entry for every pass
# whether or not drawing ever ran, so its length cannot answer this: with PLOT=0
# it is still one-per-pass, and taking the first entry as the headline on that
# basis left the report with no charts and — because the "no charts, and here is
# why" note is written only when there is no headline — nothing saying so.
has_graphs() { # <pass id>
  local f
  for f in "$PLOTDIR/$1"/*.svg; do
    [ -f "$f" ] && return 0
  done
  return 1
}
if [ "$REPEATS" -gt 1 ] && [ "$agg_graphed" = 1 ]; then
  HEADLINE_GRAPHS="aggregate"
  HEADLINE_SUFFIX=" (mean of $REPEATS passes)"
  HEADLINE_GRAPH_NOTE="
The suite ran ${REPEATS} times. Each chart below is the mean across those passes,
with the band behind it spanning the slowest and fastest pass at that moment —
so the line is what to expect and the width of the band is how much the storage
disagreed with itself. A band that stays narrow is a backend under control; one
that flares is a backend whose behaviour depends on something not being
measured here. The passes are also plotted separately in
[pass by pass](#pass-by-pass)."
elif [ ${#RUN_IDS[@]} -gt 0 ] && has_graphs "${RUN_IDS[0]}"; then
  HEADLINE_GRAPHS="${RUN_IDS[0]}"
fi

# The three charts for one test, if they were drawn. The alt text doubles as the
# caption: render_html lifts a paragraph that holds nothing but an image into a
# <figure> and reuses it as the <figcaption>, which is as close as Markdown gets
# to AsciiDoc's `.Title`.
emit_graphs() { # <graph basename> <caption subject> [pass id]
  local base="$1" subject="$2" rid="${3:-$HEADLINE_GRAPHS}" suffix key cap spec
  [ -n "$rid" ] || return 0
  case "$rid" in
  compare) suffix=" (all $REPEATS passes)" ;;
  "$HEADLINE_GRAPHS") suffix="$HEADLINE_SUFFIX" ;;
  *) suffix=" ($rid)" ;;
  esac

  local specs=("iops:IOPS" "bw:Bandwidth" "clat:Completion latency")
  [ "$base" = pgbench ] &&
    specs=("tps:Transaction rate" "lat:Mean latency" "maxlat:Worst latency")

  for spec in "${specs[@]}"; do
    key="${spec%%:*}"
    cap="${spec#*:}"
    [ -f "$PLOTDIR/$rid/${base}_${key}.svg" ] || continue
    echo "![${cap} — ${subject}${suffix}](graphs/${rid}/${base}_${key}.svg)"
    echo
  done
}

log "Writing report"

{
  cat <<EOF
# Storage Benchmark Report

| Property | Value |
| -------- | ----- |
| Generated         | $(date -u '+%Y-%m-%d %H:%M:%S UTC')$([ -n "$REPLOT_DIR" ] && echo " (--replot)") |
| Label             | ${LABEL:-n/a} |
| Total runtime     | ${ELAPSED_LABEL} |
| Host / pod        | $(uname -n) |
| Kernel            | $(uname -r) |
| Running as        | uid $(id -u), gid $(id -g) |
| fio version       | $(fio --version 2>/dev/null) |
| postgres version  | ${PG_VERSION} |
| Mounts under test | ${USABLE[*]} |
| Run order         | $ORDER |

## Test parameters

| Parameter | Value |
| --------- | ----- |
| Run order             | ${ORDER} |
| Passes over the suite | ${REPEATS} |
| Settle between runs   | ${SETTLE}s |
| Settle between tests  | ${TEST_SETTLE}s |
| fio working set       | ${FIO_SIZE} |
| fio runtime per job   | ${FIO_RUNTIME}s |
| fio ioengine          | ${IOENGINE} |
| fio log sample window | ${LOG_AVG_MSEC}ms |
| pgbench               | $([ "$have_pgbench" = 1 ] && echo "scale ${PGBENCH_SCALE}, ${PGBENCH_CLIENTS} clients, ${PGBENCH_JOBS} threads, ${PGBENCH_MODE}, ${PGBENCH_WARMUP}s warmup + ${PGBENCH_TIME}s measured" || echo "not run") |

## Reading these numbers

* Run order was \`${ORDER}\`. In \`by-mount\` each mount gets an uninterrupted block of tests; in \`by-test\` the mounts are paired closely in time so shared backend load hits both about equally. If the two paths share physical hardware, \`by-test\` is the fairer head-to-head.
* A ${SETTLE}s idle period separates consecutive runs, and a shorter ${TEST_SETTLE}s one separates consecutive tests within a run, so that one job's writeback does not land inside the next job's first samples.
* What each fio job measures, and the exact command it ran, is in [fio tests](#fio-tests) — including the flags all of them share, such as \`--direct=1\` to keep the page cache out of the results. If you read one section before the numbers, read that one.
* \`seq_write_1m\`, \`seq_write_zero_1m\` and \`seq_write_rand_1m\` are the same job with different data in the buffer: whatever fio writes by default, all zeros, and fresh random bytes per block. On a backend that stores what it is given they are one number three times. Where they diverge, the backend is looking at the content — zeros compressing away, or identical blocks being deduplicated — and the write figures for real data are somewhere between the two extremes rather than at either.
* If you are comparing storage classes and only have time for one number, it is \`fsync_8k_qd1\` — or, if you would rather have one an application would recognise, the pgbench TPS in [pgbench](#pgbench).
* fio measures the storage. [pgbench](#pgbench) measures what a database gets out of it, which is always less: the same commit that fio counts as one 8 KiB write is, in postgres, a WAL record, an fsync, a heap and index page to write back later, and a full-page image if a checkpoint has just been through. Where the two disagree about which mount is faster, pgbench is the one that resembles a workload.
* Latency columns are mean completion latency in microseconds. Bandwidth columns are KiB/s as reported by fio.
* The tables are whole-run averages. An average hides the shape of a run, and the shape is often the interesting part — a cache filling up, a throttle kicking in, a backend stalling. The time-series chart under each test in [fio tests](#fio-tests) is where that shows.

## Mount points

EOF

  for mp in "${USABLE[@]}"; do
    sl="$(slug "$mp")"
    echo "### $mp"
    echo
    echo '```text'
    cat "$MOUNTINFO/df_${sl}.txt" 2>/dev/null
    echo
    cat "$MOUNTINFO/mount_${sl}.txt" 2>/dev/null
    echo '```'
    echo
  done

  # ---- what each fio job actually ran ------------------------------------
  cat <<EOF
## fio tests

${#FIO_TESTS[@]} jobs, each isolating one thing the storage can be bad at. Every
one of them is also given these flags, which are what make the numbers
comparable:

* \`--direct=1\` — O_DIRECT, so reads and writes go to the backend instead of
  being served by the page cache. Without it most of these tests would be
  measuring RAM.
* \`--time_based --runtime=${FIO_RUNTIME}\` — each job runs for a fixed ${FIO_RUNTIME} seconds,
  looping over its file if it finishes early. Every mount therefore gets equal
  **time** rather than equal **bytes**, so a slow backend cannot shorten its own run.
* \`--ioengine=${IOENGINE}\` — how I/O is submitted to the kernel; an asynchronous
  engine such as the default \`libaio\` is what lets a queue depth above 1 mean
  anything. The commit-latency test overrides it with \`psync\`, which blocks on
  each write, because blocking is the thing it is measuring.
* \`--group_reporting\` — with more than one worker, report the aggregate rather
  than each worker separately.
* \`--directory\` — the mount under test. It is the only flag that differs between
  mounts — everything below is identical for all of them.

The command shown under each test is the one that ran, recorded as it ran, and
below it is what the storage did while it ran.

Every fio job logs itself as a time series, one sample per ${LOG_AVG_MSEC}ms window, and
that is what those charts are. The x axis is elapsed time **within that job**,
so runs on different mounts line up even when they were minutes apart on the
clock. Where a job does both reads and writes (\`rand_rw_70_30_4k\`) each
direction is a separate line. Multi-job tests have their per-job samples summed
for IOPS and bandwidth and averaged for latency, so the lines are the aggregate
the tables report, not one worker's share of it. Latency uses a logarithmic y
axis — storage latency spans orders of magnitude and a linear axis flattens
everything below the worst spike into the baseline.

What to look for: a flat line is a backend holding its service level; a decaying
curve is usually a cache or write buffer filling; periodic collapses to near
zero are flush or compaction stalls, which the whole-run averages in the table
below will not show you at all.
${HEADLINE_GRAPH_NOTE}
EOF

  for t in "${FIO_TESTS[@]}"; do
    echo "### $t"
    echo
    fio_test_purpose "$t"
    echo
    if [ -n "${FIO_ARGS[$t]:-}" ]; then
      echo '```console'
      echo "\$ fio --directory=<mount> ${FIO_ARGS[$t]}"
      echo '```'
      echo
    fi
    emit_graphs "$t" "$t"
  done

  cat <<'MDEOF'
## fio results

Rows appear in execution order.

MDEOF

  csv_table "$FIO_CSV"

  # ---- pgbench ----------------------------------------------------------
  echo
  echo "## pgbench"
  echo
  if [ "$have_pgbench" = 1 ]; then
    cat <<EOF
Everything above measures the storage. This measures a database on top of it,
which is the only number here an application would recognise.

A throwaway PostgreSQL ${PG_VERSION} cluster is created on each mount with
\`initdb\`, loaded to scale ${PGBENCH_SCALE} (about $((PGBENCH_SCALE * 16)) MiB of table data before
indexes), warmed for ${PGBENCH_WARMUP}s and then driven for ${PGBENCH_TIME}s through pgbench's built-in
TPC-B-like workload at ${PGBENCH_CLIENTS} concurrent clients across ${PGBENCH_JOBS} threads. Each
transaction is a handful of small updates and an insert, committed — so every
one of them costs a WAL write and an \`fsync\` before the client is told it
succeeded.

The warmup is discarded. Measured from cold a pgbench run does not report the
workload, it reports the decay into it: the buffer cache starts empty, the WAL
has not yet wrapped, and no checkpoint has happened, so the first seconds are
faster than anything the storage can sustain. ${PGBENCH_WARMUP}s of unmeasured traffic puts
the cluster in the state it would be in after a few minutes of real use, and
the measured run then starts there. Its numbers are still in
\`raw/<pass>/pgbench_<mount>.txt\` if you want to see how far off the cold start
was. \`--no-vacuum\` on the measured run keeps that state rather than letting
pgbench's usual pre-run vacuum undo it.

Statements go over the wire as \`${PGBENCH_MODE}\` (\`PGBENCH_MODE\`). pgbench
defaults to \`simple\`, which makes the server parse and plan every statement
again on each execution — at which point a good part of what is being measured
is postgres reading SQL rather than the storage underneath it. Real
applications, and every connection pooler, use prepared statements.

That commit path is why this tracks \`fsync_8k_qd1\` more closely than any other
test here, and why the two can still disagree: postgres adds a WAL record, a
heap and index page the checkpointer has to write back later, and a full-page
image for the first write to each page after a checkpoint. Write amplification
of several times the logical change is normal, and a backend that does well on
raw \`fsync\` but badly here is usually one that copes with a steady trickle of
small writes but not with the burst a checkpoint delivers.

The cluster runs with \`fsync\`, \`synchronous_commit\` and \`full_page_writes\` all
on, which are the defaults, stated so that what was measured is on the record.
\`max_wal_size\` is raised to ${PGBENCH_MAX_WAL} from the 1 GB default: at 1 GB a mount that
absorbs writes quickly checkpoints every few seconds, which is a property of
the default rather than of any tuned database, and it dominates the run.
\`shared_buffers\` is left at its 128 MB default on purpose, in the other
direction: a cluster large enough to cache the working set would be reporting
the speed of RAM. The cluster is deleted after each mount.

| Column | Meaning |
| ------ | ------- |
| \`init_s\` | seconds to load the data — bulk write throughput, as pgbench timed it |
| \`tps\` | transactions per second over the timed run, excluding connection setup |
| \`latency_avg_ms\` | mean time to commit one transaction |
| \`failed\` | transactions rolled back; anything but 0 makes \`tps\` suspect |

EOF
    csv_table "$PG_CSV"

    if [ "$pgbench_graphed" = 1 ]; then
      cat <<'EOF'

pgbench aggregates its own log into fixed intervals and one second is the
finest it will accept, so these are coarser than the fio charts above — a stall
shorter than a second is inside a sample rather than visible as one. The worst
latency chart is the one to read for that: it plots the slowest single
transaction in each interval, so a checkpoint or an fsync stall that the mean
absorbs still shows as a spike.

EOF
      emit_graphs pgbench pgbench
    fi
  else
    cat <<'EOF'
Not run. The suite normally finishes with a real workload — a throwaway
PostgreSQL cluster per mount, driven through pgbench's TPC-B-like transaction —
because it is the only number here that carries a WAL, a checkpointer and a
page cache rather than measuring the storage directly.

It was skipped: either `PGBENCH=0` was set, postgres is not in this image, the
benchmark is running as root (postgres refuses to), or the uid it runs as has
no `/etc/passwd` entry, which postgres needs to resolve its own identity. The
run summary printed at the end says which.
EOF
  fi

  # ---- per-pass detail --------------------------------------------------
  # Only worth a section when there is more than one pass. With a single pass
  # its charts are already the ones sitting next to the prose above, and
  # repeating them here would just double the size of the HTML.
  if [ "$REPEATS" -gt 1 ] && [ -n "$HEADLINE_GRAPHS" ]; then
    cat <<EOF

## Pass by pass

The charts above are the mean of ${REPEATS} passes. These are the passes
themselves, in the order they ran, for when the aggregate hides something the
mean should not have smoothed: a first pass that was slower than the rest
because a cache was cold, or one pass that stalled and pulled the band wide on
its own.

Each pass is a complete run of the suite, separated from the next by the same
${SETTLE}s cooldown that separates runs within a pass.

EOF

    if [ "$cmp_graphed" = 1 ]; then
      cat <<'EOF'
### Every pass on one axis

Each chart here is one test with every pass drawn on it, unaggregated. The
colour is the series — the mount, and the direction where a test does both —
and the dash pattern is the pass, so the same series across passes stays
recognisably the same series.

This is the chart that says *which* pass disagreed, which the band on the
aggregate cannot: a first pass slower than the rest because a cache was cold
and one pass in three stalling at random produce the same width of band and
mean very different things.

EOF
      for t in "${FIO_TESTS[@]}"; do
        emit_graphs "$t" "$t" compare
      done
      [ "$pgbench_graphed" = 1 ] && emit_graphs pgbench pgbench compare
    fi

    for rid in "${RUN_IDS[@]}"; do
      echo "### $rid"
      echo
      for t in "${FIO_TESTS[@]}"; do
        emit_graphs "$t" "$t" "$rid"
      done
      [ "$pgbench_graphed" = 1 ] && emit_graphs pgbench pgbench "$rid"
    done
  fi

  if [ -z "$HEADLINE_GRAPHS" ]; then
    echo
    if [ "$have_plot" = 1 ]; then
      echo "No time-series samples were produced — every fio job failed, or the"
      echo "runs were shorter than one ${LOG_AVG_MSEC}ms sample window."
    else
      echo "Graphs were skipped: \`PLOT=0\` was set. The underlying logs are"
      echo "still under \`fio-logs/\` and can be plotted after the fact."
    fi
    echo
  fi

  cat <<MDEOF
## Raw output

Everything a pass produced sits under that pass's own directory, \`run-01\`,
\`run-02\` and so on, because fio names its logs after the test rather than after
the attempt and a second pass would otherwise overwrite the first.

\`raw/<pass>/\` holds fio's terse lines, one file per test per mount. They are
terse version 3 records — useful if you want latency percentiles or bandwidth
min/max, which are not carried into the CSV above. \`raw/pgbench_<mount>.txt\` in the same directory holds everything pgbench
and initdb printed, and \`raw/<pass>/pgbench_<mount>_server.log\` the postgres
server log for that mount — checkpoint and autovacuum activity land there, which
is usually where an unexplained dip in the transaction rate is explained. The
\`df\` and \`/proc/mounts\` captures are properties of the mount rather than of a
pass, so they sit above the per-pass directories in \`raw/\` itself.

\`fio-logs/<pass>/\` holds fio's own time-series logs, named
\`<mount>_<test>_{bw,iops,lat,slat,clat}.log\`, in fio's usual
\`time_ms, value, ddir, blocksize, offset\` format (\`ddir\` 0 = read, 1 = write).
Bandwidth is KiB/s, latency is nanoseconds. Alongside them are pgbench's
aggregate logs, \`pgbench_<mount>.<pid>[.<thread>]\`, one row per second per
thread as \`interval_start num_transactions sum_latency sum_latency_2
min_latency max_latency\` with latencies in microseconds.

These are the unprocessed inputs to the charts above, and the fio ones are in
fio's standard log format, so \`fio2gnuplot\` and \`fiologparser.py\` will read them
if you want to re-plot them differently. Neither ships in this image — both are
Python, and CPython is most of what a benchmark image would otherwise carry.

\`graphs/<pass>/\` holds the rendered SVGs, each alongside the \`.meta\` file that
says how it was drawn — which series, in which colour, band or dashed — and
\`graphs/data/<pass>/\` the reduced series themselves, so any chart can be
redrawn without re-running the benchmark:

\`\`\`console
\$ awk -v META=graphs/${HEADLINE_GRAPHS:-run-01}/rand_read_4k_iops.meta \\
    -v TITLE="IOPS over time" -v XLABEL="elapsed (s)" -v YLABEL=IOPS \\
    -f graphs/render-chart.awk graphs/data/${HEADLINE_GRAPHS:-run-01}/*rand_read_4k_iops_read.dat \\
    > rand_read_4k_iops.svg
\`\`\`

\`graphs/render-chart.awk\` is the one script that drew every chart in this
report — it needs nothing but awk, and it is what \`--replot\` (see below) reruns
against the reduced series to rebuild the graphs and the report without
touching fio or pgbench again.

The aggregate charts are in \`graphs/aggregate/\`, drawn from
\`graphs/data/aggregate_*.dat\`, whose columns are \`time mean min max\`.

### Regenerating this report

Everything the report and the graphs are built from — the CSVs, the fio and
pgbench logs, the reduced \`.dat\` series — is still here. To redraw the graphs
and rebuild the Markdown/HTML from them, without repeating the benchmark
itself:

\`\`\`console
\$ ./storage-bench.sh --replot $OUTDIR
\`\`\`

This is also how a change to \`storage-bench.sh\`'s drawing or reporting code is
tried out against a real run: point \`--replot\` at any \`bench-results-*\`
directory, including one from an older version of the script, and only the
graphs and report are touched.
MDEOF
} >"$MD"

# ---------------------------------------------------------------------------
# Render
#
# cmark-gfm turns the Markdown into an HTML fragment and nothing else — no
# document, no stylesheet, no table of contents, and no way to inline an image.
# It is chosen for exactly that: it is a ~1 MB C program with no dependencies
# beyond libc, where the alternatives are a Ruby or a Haskell runtime, either of
# which would be the largest thing in the image by a wide margin. The three
# things it does not do are done below instead.
#
# The result is one self-contained file: the stylesheet is embedded and every
# graph's SVG markup is spliced in directly, so the HTML can be mailed or
# copied out of a pod on its own without dragging graphs/ along with it. Inline
# rather than a data: URI, as an <img> once held: a chart's hover tooltip is a
# <script> baked into its SVG (see render-chart.awk), and a script inside an
# <img src="data:image/svg+xml..."> never runs — the browser treats an <img>'s
# SVG as a static image regardless of what is inside it.
# ---------------------------------------------------------------------------

# The page shell. Light and dark are both styled because this is read in a
# browser, but graph figures keep a white plate in either: the SVGs
# render-chart.awk draws have a hard-coded white background and dark axis
# text, so they need one.
html_head() {
  cat <<'MDEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Storage Benchmark Report</title>
<style>
:root {
  color-scheme: light dark;
  --bg: #fff; --fg: #1c1e21; --muted: #62676c; --rule: #dcdfe3;
  --accent: #1a6ec4; --code-bg: #f4f5f7; --head-bg: #eef1f4; --toc-bg: #fafbfc;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #16181c; --fg: #d5d9de; --muted: #979ca3; --rule: #2f333a;
    --accent: #6cb0f0; --code-bg: #1e2126; --head-bg: #22262c; --toc-bg: #1a1d21;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--fg);
  font: 16px/1.6 system-ui, -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
}
code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }

#toc {
  position: fixed; top: 0; left: 0; bottom: 0; width: 19rem; overflow-y: auto;
  padding: 1.5rem 1rem; background: var(--toc-bg);
  border-right: 1px solid var(--rule); font-size: 0.875rem;
}
.toc-title {
  margin: 0 0 0.75rem; font-weight: 600; letter-spacing: 0.06em;
  text-transform: uppercase; font-size: 0.75rem; color: var(--muted);
}
#toc ul { list-style: none; margin: 0; padding: 0; }
#toc li { margin: 0.15rem 0; }
#toc a { color: var(--fg); text-decoration: none; display: block; padding: 0.1rem 0; }
#toc a:hover { color: var(--accent); text-decoration: underline; }
#toc .toc-l3 { padding-left: 1.1rem; color: var(--muted); }
#toc .secnum { color: var(--muted); margin-right: 0.35rem; }

#content { max-width: 62rem; margin: 0 0 0 19rem; padding: 2.5rem 2.5rem 6rem; }
@media (max-width: 60rem) {
  #toc { position: static; width: auto; height: auto; border-right: 0;
         border-bottom: 1px solid var(--rule); }
  #content { margin-left: 0; padding: 1.5rem 1.25rem 4rem; }
}

h1, h2, h3 { line-height: 1.25; font-weight: 600; }
h1 { font-size: 2rem; margin: 0 0 1.5rem; }
h2 { font-size: 1.5rem; margin: 2.5rem 0 1rem; padding-bottom: 0.3rem;
     border-bottom: 1px solid var(--rule); }
h3 { font-size: 1.15rem; margin: 2rem 0 0.75rem; }
h2 .secnum, h3 .secnum { color: var(--muted); font-weight: 400; margin-right: 0.4rem; }

a { color: var(--accent); }
p, ul, ol { margin: 0 0 1rem; }
li { margin: 0.25rem 0; }

.tablewrap { overflow-x: auto; margin: 0 0 1.25rem; }
table { border-collapse: collapse; font-size: 0.9rem; }
th, td { border: 1px solid var(--rule); padding: 0.35rem 0.7rem; text-align: left;
         white-space: nowrap; }
thead th { background: var(--head-bg); font-weight: 600; }
tbody tr:nth-child(even) { background: var(--code-bg); }

pre {
  background: var(--code-bg); border: 1px solid var(--rule); border-radius: 4px;
  padding: 0.75rem 1rem; overflow-x: auto; font-size: 0.85rem; line-height: 1.45;
  margin: 0 0 1.25rem;
}
pre code { background: none; padding: 0; }
code { background: var(--code-bg); border-radius: 3px; padding: 0.1em 0.2em;
       font-size: 0.875em; }

figure { margin: 0 0 1.75rem; }
figure img, figure svg {
  display: block; width: 100%; height: auto; background: #fff;
  border: 1px solid var(--rule); border-radius: 4px; padding: 0.25rem;
}
figcaption { margin-top: 0.4rem; font-size: 0.85rem; color: var(--muted); }
</style>
</head>
<body>
MDEOF
}

html_foot() {
  printf '</body>\n</html>\n'
}

# cmark-gfm's fragment, plus the four things it leaves out: heading ids,
# section numbers, a table of contents, and inlined images. Everything is held
# in memory because the contents page has to be printed before the body it was
# built from; the fragment is a few hundred KiB, the graphs are not in it yet.
decorate() { # <base dir the markdown's graphs/... image paths are relative to>
  awk -v basedir="$1" '
    # Anchors are GitHub-compatible — lowercased, punctuation dropped, spaces
    # hyphenated, duplicates suffixed -1, -2 — so the intra-document links in
    # the Markdown resolve both here and when the .md is viewed on a forge.
    function striptags(s) { gsub(/<[^>]*>/, "", s); return s }
    function slugify(s,   t) {
      t = striptags(s)
      gsub(/&[#0-9a-zA-Z]+;/, "", t)
      t = tolower(t)
      gsub(/[^a-z0-9 _-]/, "-", t)
      gsub(/ +/, "-", t)
      gsub(/-+/, "-", t)
      sub(/^-/, "", t)
      sub(/-$/, "", t)
      return t
    }

    { line[++n] = $0 }

    END {
      for (i = 1; i <= n; i++) {
        if (line[i] !~ /^<h[23][^>]*>/) continue
        lvl = substr(line[i], 3, 1) + 0
        inner = line[i]
        sub(/^<h[23][^>]*>/, "", inner)
        sub(/<\/h[23]>[ \t]*$/, "", inner)

        base = slugify(inner)
        if (base == "") base = "section"
        if (base in seen) { id = base "-" seen[base]; seen[base]++ }
        else { id = base; seen[base] = 1 }

        if (lvl == 2) { n2++; n3 = 0; num = n2 "." }
        else { n3++; num = n2 "." n3 "." }

        hlvl[i] = lvl; hid[i] = id; hnum[i] = num; htxt[i] = inner
        toc[++tn] = sprintf("<li class=\"toc-l%d\">" \
          "<a href=\"#%s\"><span class=\"secnum\">%s</span>%s</a></li>",
          lvl, id, num, inner)
      }

      print "<nav id=\"toc\" aria-label=\"Contents\">"
      print "<p class=\"toc-title\">Contents</p>"
      if (tn > 0) {
        print "<ul>"
        for (i = 1; i <= tn; i++) print toc[i]
        print "</ul>"
      }
      print "</nav>"

      print "<main id=\"content\">"
      for (i = 1; i <= n; i++) {
        l = line[i]

        if (i in hid) {
          printf "<h%d id=\"%s\"><span class=\"secnum\">%s</span>%s</h%d>\n",
            hlvl[i], hid[i], hnum[i], htxt[i], hlvl[i]
          continue
        }

        # A paragraph containing nothing but an image becomes a captioned
        # figure, with the alt text serving as the caption, and the image
        # itself — always one of our own charts — is spliced in as real SVG
        # markup rather than left as an <img src="graphs/...">: the hover
        # tooltip on every chart is a <script> baked into its SVG, and a
        # script inside an <img>, data: URI or not, never runs.
        if (l ~ /^<p><img [^>]*\/><\/p>$/) {
          img = l
          sub(/^<p>/, "", img)
          sub(/<\/p>$/, "", img)
          alt = ""
          if (match(img, /alt="[^"]*"/))
            alt = substr(img, RSTART + 5, RLENGTH - 6)
          src = ""
          if (match(img, /src="[^"]*"/))
            src = substr(img, RSTART + 5, RLENGTH - 6)

          svg = ""
          if (src != "") {
            fpath = basedir "/" src
            while ((getline sline < fpath) > 0) svg = svg sline "\n"
            close(fpath)
          }
          if (svg == "") svg = "<p><em>[graph missing: " src "]</em></p>"

          print "<figure>" svg \
            (alt == "" ? "" : "<figcaption>" alt "</figcaption>") "</figure>"
          continue
        }

        # Wide tables (fio results is eight columns) scroll inside their own
        # box rather than pushing the page sideways.
        if (l == "<table>") { print "<div class=\"tablewrap\">"; print l; continue }
        if (l == "</table>") { print l; print "</div>"; continue }

        print l
      }
      print "</main>"
    }
  '
}

render_html() { # <markdown> <html out>
  local md="$1" out="$2" rc

  {
    html_head
    cmark-gfm --unsafe -e table -e autolink "$md" | decorate "$OUTDIR"
    html_foot
  } >"$out"
  rc=$?

  return $rc
}

HTML=""

if [ "$RENDER" = "html" ]; then
  log "Rendering report"
  info "HTML ..."
  html_out="$OUTDIR/storage-benchmark-report.html"
  if render_html "$MD" "$html_out" 2>"$RAWDIR/render.log" &&
    [ -s "$html_out" ]; then
    HTML="$html_out"
  else
    info "  FAILED (see $RAWDIR/render.log)"
  fi
fi

# ---------------------------------------------------------------------------
# Archive
#
# A finished run is a few thousand files, and the machine it was measured on is
# usually not the one it gets read on, so it is tarred up as the last thing
# before the summary. The archive is written next to the run directory rather
# than inside it, so it does not have to exclude itself and so a second run's
# archive does not disappear into the first one's folder.
#
# With RUNDIR empty the run directory *is* OUTBASE and there is no "next to",
# so the archive goes inside and excludes itself by name.
# ---------------------------------------------------------------------------
ARCHIVE_PATH=""

if [ "$ARCHIVE" = "1" ]; then
  log "Archiving results"
  if ! command -v tar >/dev/null 2>&1; then
    info "tar not found in PATH — skipping"
    MISSING+=("tar — the results were not archived")
  else
    if [ -n "$RUNDIR" ]; then
      archive="$OUTBASE/${RUNDIR}.tar.gz"
      tar_args=(-C "$OUTBASE" "$RUNDIR")
    else
      # The archive has to live in the directory it is archiving, so tar is
      # given the top-level entries by name rather than `.`. Excluding it from a
      # walk of `.` is not enough: tar still stats the directory it is writing
      # into, sees it change underneath itself, and exits 1 with "file changed
      # as we read it" — which is indistinguishable from a real failure.
      archive="$OUTDIR/storage-bench-results.tar.gz"
      tar_args=(-C "$OUTDIR")
      for e in "$OUTDIR"/*; do
        [ -e "$e" ] || continue
        [ "$e" = "$archive" ] && continue
        tar_args+=("${e##*/}")
      done
    fi

    if tar -czf "$archive" "${tar_args[@]}" 2>"$RAWDIR/tar.log"; then
      ARCHIVE_PATH="$archive"
      info "$(du -h "$archive" | cut -f1)  $archive"
    else
      info "FAILED (see $RAWDIR/tar.log)"
      MISSING+=("tar — the results were not archived")
      rm -f "$archive"
    fi
  fi
fi

echo
if [ -n "$REPLOT_DIR" ]; then
  echo "Replotted in ${ELAPSED}s."
else
  echo "Done in ${ELAPSED}s."
fi
[ -n "$ARCHIVE_PATH" ] && echo "  Archive  : $ARCHIVE_PATH"
echo "  Report   : $MD"
[ -n "$HTML" ] && echo "             $HTML"
echo "  CSVs     : $FIO_CSV"
[ "$have_pgbench" = 1 ] && echo "             $PG_CSV"
if [ "$have_plot" = 1 ]; then
  echo "  Graphs   : $PLOTDIR/"
fi
echo "  fio logs : $LOGDIR/"
echo "  Raw      : $RAWDIR/"

# Repeated here because the notes above were printed before a run that may have
# taken an hour, and an incomplete report is worth noticing now rather than
# after the machine under test has moved on.
if [ ${#MISSING[@]} -gt 0 ]; then
  echo
  echo "WARNING: this report is incomplete — tools missing from PATH:"
  for m in "${MISSING[@]}"; do echo "  - $m"; done
  echo
  echo "  The container image ships all of them. On a host, nix-shell does too:"
  echo "    nix-shell --run '$0 ${USABLE[*]}'"
  echo "  Set PLOT=0 / RENDER=none to make the omission deliberate and silent."
fi

if [ -z "$HTML" ]; then
  echo
  echo "The Markdown is readable as it stands. To render it elsewhere, from $OUTDIR"
  echo "so that the relative graphs/ paths resolve:"
  echo "  pandoc -s --toc --embed-resources -o report.html storage-benchmark-report.md"
  echo "  pandoc -o report.pdf storage-benchmark-report.md   # -> PDF, needs a TeX engine"
fi
