#!/usr/bin/env bash
#
# storage-bench.sh — dd + fio + pgbench benchmark across one or more mounted
#                    PVCs, emitting CSV data files and a Markdown report.
#
# Usage:
#   ./storage-bench.sh /data/ceph /data/portworx
#   ORDER=by-test ./storage-bench.sh /data/ceph /data/portworx
#
# The graphs need gnuplot and the rendered report needs cmark-gfm, neither of
# which a host necessarily has; both are in the image, and shell.nix puts the
# same set on a host:
#   nix-shell --run './storage-bench.sh /tank/backup'
# Without them the benchmark still runs, it just produces a thinner report and
# says so at the end.
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
# Tunables (env vars):
#   OUTBASE       directory the run dir goes in (default /tmp)
#   RUNDIR        this run's directory inside it
#                                               (default bench-results-<timestamp>;
#                                                set it empty to write straight
#                                                into OUTBASE)
#   ORDER         by-mount | by-test            (default by-mount)
#   SETTLE        seconds to idle between runs  (default 15)
#   DD_ZERO_MB    size of the dd zero write     (default 1024)
#   DD_RAND_MB    size of the dd urandom write  (default 256)
#   FIO_SIZE      fio working set per job       (default 2G)
#   FIO_RUNTIME   seconds per fio job           (default 30)
#   IOENGINE      fio ioengine                  (default libaio)
#   LOG_AVG_MSEC  fio time-series sample window (default 100)
#   PGBENCH       1|0, run the postgres workload(default 1)
#   PGBENCH_SCALE pgbench scale factor          (default 100, ~1.6 GiB)
#   PGBENCH_CLIENTS  concurrent pgbench clients (default 8)
#   PGBENCH_JOBS  pgbench worker threads        (default 4)
#   PGBENCH_TIME  seconds of timed pgbench run  (default 60)
#   PLOT          1|0, draw the gnuplot graphs  (default 1)
#   RENDER        html|none                     (default html)
#
# dd and fio measure the storage directly. pgbench measures what a real
# application gets out of it: a throwaway PostgreSQL cluster is initialised on
# each mount in turn, loaded, and driven through the built-in TPC-B-like
# workload. The numbers are lower than fio's and that is the point — they carry
# the WAL, the checkpointer and the page cache that sit between an application
# and the disk, none of which fio models.
#
# Runs unprivileged — no root, no SCC changes needed. PostgreSQL refuses to run
# as root, so the pgbench workload is skipped rather than run in that case.

set -uo pipefail
export LC_ALL=C

MOUNTS=("$@")
[ ${#MOUNTS[@]} -eq 0 ] && echo "Usage: $0 <mount1> [<mount2> ...]" >&2 && exit 1

TS="$(date +%Y%m%d-%H%M%S)"
# Where the results go, in two parts, so that pointing the benchmark at a
# mounted volume does not also flatten every run into the same directory. The
# volume is OUTBASE and stays put; RUNDIR is per-run and carries the timestamp,
# so consecutive runs sit side by side instead of overwriting each other.
#
# OUTDIR is still read, as the base, because that is the variable callers were
# passing the volume in before this was split — an old `OUTDIR=/out` now means
# `/out/bench-results-<timestamp>` rather than being silently ignored. Setting
# RUNDIR empty restores the flat behaviour.
OUTBASE="${OUTBASE:-${OUTDIR:-/tmp}}"
RUNDIR="${RUNDIR-bench-results-$TS}"
OUTDIR="$OUTBASE${RUNDIR:+/$RUNDIR}"
ORDER="${ORDER:-by-mount}"
SETTLE="${SETTLE:-15}"
DD_ZERO_MB="${DD_ZERO_MB:-10240}"
DD_RAND_MB="${DD_RAND_MB:-10240}"
FIO_SIZE="${FIO_SIZE:-10G}"
FIO_RUNTIME="${FIO_RUNTIME:-60}"
IOENGINE="${IOENGINE:-libaio}"
LOG_AVG_MSEC="${LOG_AVG_MSEC:-100}"
PGBENCH="${PGBENCH:-1}"
PGBENCH_SCALE="${PGBENCH_SCALE:-100}"
PGBENCH_CLIENTS="${PGBENCH_CLIENTS:-8}"
PGBENCH_JOBS="${PGBENCH_JOBS:-4}"
PGBENCH_TIME="${PGBENCH_TIME:-60}"
PLOT="${PLOT:-1}"
RENDER="${RENDER:-html}"

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
# hour into the run, after dd and fio have already been paid for.
for v in PGBENCH_SCALE PGBENCH_CLIENTS PGBENCH_JOBS PGBENCH_TIME; do
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

# pgbench divides its clients between its threads and refuses the run outright
# if the division leaves a thread with none.
[ "$PGBENCH_JOBS" -le "$PGBENCH_CLIENTS" ] || {
  echo "PGBENCH_JOBS ($PGBENCH_JOBS) cannot exceed PGBENCH_CLIENTS ($PGBENCH_CLIENTS)" >&2
  exit 1
}

DD_CSV="$OUTDIR/dd_results.csv"
FIO_CSV="$OUTDIR/fio_results.csv"
PG_CSV="$OUTDIR/pgbench_results.csv"
MD="$OUTDIR/storage-benchmark-report.md"
RAWDIR="$OUTDIR/raw"
LOGDIR="$OUTDIR/fio-logs" # fio's own time-series logs, one set per test
PLOTDIR="$OUTDIR/graphs"  # the SVGs the report embeds
PLOTDATA="$PLOTDIR/data"  # per-series gnuplot input, kept for re-plotting

mkdir -p "$RAWDIR" "$LOGDIR" "$PLOTDATA" || {
  echo "cannot create $OUTDIR" >&2
  exit 1
}

# Tests in execution order. Read tests depend on the write test that precedes
# them, so this order matters in both ORDER modes.
TESTS=(
  dd_write_zero
  dd_write_urandom
  dd_read
  seq_write_1m
  seq_read_1m
  rand_write_4k
  rand_read_4k
  rand_rw_70_30_4k
  fsync_8k_qd1
  pgbench
)

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

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v fio >/dev/null 2>&1 || {
  echo "fio not found in PATH" >&2
  exit 1
}

# Graphs and rendering are optional extras: a missing tool degrades the report
# rather than failing the benchmark, which by then has already been paid for.
# MISSING collects what was degraded so it can be repeated at the end — a
# benchmark runs for long enough that a warning printed up here has scrolled
# well out of sight by the time anyone looks at the results.
MISSING=()

have_gnuplot=0
if [ "$PLOT" = "1" ] && command -v gnuplot >/dev/null 2>&1; then
  have_gnuplot=1
elif [ "$PLOT" = "1" ]; then
  echo "NOTE gnuplot not found in PATH — the report will have NO GRAPHS" >&2
  MISSING+=("gnuplot — the report has no graphs")
fi

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

# The socket lives off the mount under test, in TMPDIR, for two reasons: a unix
# socket on the storage being hammered is not something to measure, and the
# path has to fit in sockaddr_un.sun_path, which is 108 bytes including the
# ".s.PGSQL.5432" the server appends. A deep OUTDIR would blow that; TMPDIR
# usually will not, and if it does the workload is skipped rather than failing
# halfway through the run.
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
echo "Settle       : ${SETTLE}s between runs"
echo "Results dir  : $OUTDIR"

# Register the files we will create so cleanup can remove them.
for mp in "${USABLE[@]}"; do
  CREATED+=("$mp/ddbench.zero" "$mp/ddbench.rand"
    "$mp/fio_seq.dat" "$mp/fio_rand.dat" "$mp/fio_mix.dat" "$mp/fio_sync.dat")
  sl="$(slug "$mp")"
  df -h "$mp" >"$RAWDIR/df_${sl}.txt" 2>&1
  # /proc/mounts rather than mount(8): the same device/fstype/options in the
  # same fstab columns, and it keeps util-linux out of the image entirely, which
  # was ~25 MB once its PAM and systemd links are counted. mount(8) is the
  # fallback for a host that has no /proc.
  if [ -r /proc/mounts ]; then
    grep -F "$mp" /proc/mounts >"$RAWDIR/mount_${sl}.txt" 2>&1
  elif command -v mount >/dev/null 2>&1; then
    mount | grep -F "$mp" >"$RAWDIR/mount_${sl}.txt" 2>&1
  fi
done

echo "mount,test,size_mb,throughput,elapsed_s" >"$DD_CSV"
echo "mount,test,read_iops,read_bw_kibs,read_clat_mean_us,write_iops,write_bw_kibs,write_clat_mean_us" >"$FIO_CSV"
[ "$have_pgbench" = 1 ] &&
  echo "mount,scale,clients,threads,duration_s,init_s,tps,latency_avg_ms,transactions,failed" >"$PG_CSV"

# ---------------------------------------------------------------------------
# dd helpers
# ---------------------------------------------------------------------------
# dd prints its summary to stderr as:
#   1073741824 bytes (1.1 GB, 1.0 GiB) copied, 3.5 s, 307 MB/s
# Split on commas and take the last two fields.
parse_dd() {
  local out="$1" line
  line="$(printf '%s\n' "$out" | tail -1)"
  DD_SPEED="$(printf '%s' "$line" | awk -F, '{gsub(/^ +| +$/,"",$NF); print $NF}')"
  DD_ELAPSED="$(printf '%s' "$line" | awk -F, '{print $(NF-1)}' | sed 's/[^0-9.]//g')"
  [ -z "$DD_SPEED" ] && DD_SPEED="n/a"
  [ -z "$DD_ELAPSED" ] && DD_ELAPSED="n/a"
}

run_dd() {
  local mp="$1" name="$2" size_mb="$3"
  shift 3
  local sl
  sl="$(slug "$mp")"
  local raw="$RAWDIR/dd_${sl}_${name}.txt"
  local out rc

  info "dd $name ..."
  out="$("$@" 2>&1)"
  rc=$?
  printf '%s\n' "$out" >"$raw"

  if [ $rc -ne 0 ]; then
    info "  FAILED (see $raw)"
    echo "$mp,$name,$size_mb,FAILED,FAILED" >>"$DD_CSV"
    return 1
  fi

  parse_dd "$out"
  info "  $DD_SPEED  (${DD_ELAPSED}s)"
  echo "$mp,$name,$size_mb,$DD_SPEED,$DD_ELAPSED" >>"$DD_CSV"
}

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
    echo "$mp,$name,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED" >>"$FIO_CSV"
    return 1
  fi

  row="$(printf '%s\n' "$line" | awk -F';' -v OFS=, '{print $8, $7, $16, $49, $48, $57}')"
  info "  read: $(echo "$row" | cut -d, -f1) IOPS / write: $(echo "$row" | cut -d, -f4) IOPS"
  echo "$mp,$name,$row" >>"$FIO_CSV"
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
    "-c max_connections=$((PGBENCH_CLIENTS + 8))"
}

run_pgbench() { # <mount>
  local mp="$1" sl pgdata prefix raw out rc
  local init_s tps lat txns failed

  sl="$(slug "$mp")"
  pgdata="$mp/pgdata"
  prefix="$LOGDIR/pgbench_${sl}"
  raw="$RAWDIR/pgbench_${sl}.txt"

  local failrow="$mp,$PGBENCH_SCALE,$PGBENCH_CLIENTS,$PGBENCH_JOBS,$PGBENCH_TIME,FAILED,FAILED,FAILED,FAILED,FAILED"

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

  # ---- timed run -------------------------------------------------------
  # --log with --aggregate-interval gives one row per interval per thread,
  # which pgbench_series folds back together for the graphs. Without the
  # aggregate it would log every single transaction — millions of lines.
  info "pgbench run (${PGBENCH_CLIENTS} clients, ${PGBENCH_TIME}s) ..."
  rm -f "$prefix".*
  out="$(pgbench -h "$PG_SOCKDIR" -U postgres \
    -c "$PGBENCH_CLIENTS" -j "$PGBENCH_JOBS" -T "$PGBENCH_TIME" \
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
  echo "$mp,$PGBENCH_SCALE,$PGBENCH_CLIENTS,$PGBENCH_JOBS,$PGBENCH_TIME,$init_s,$tps,$lat,$txns,$failed" >>"$PG_CSV"

  # The cluster is ~16 MiB per scale point and the next mount wants the space.
  rm -rf "$pgdata"
}

# ---------------------------------------------------------------------------
# One test against one mount
# ---------------------------------------------------------------------------
run_test() {
  local mp="$1" test="$2"
  local zerofile="$mp/ddbench.zero"
  local randfile="$mp/ddbench.rand"

  case "$test" in

  dd_write_zero)
    run_dd "$mp" dd_write_zero "$DD_ZERO_MB" \
      dd if=/dev/zero of="$zerofile" bs=1M count="$DD_ZERO_MB" conv=fdatasync
    ;;

  # Largely a CPU benchmark — /dev/urandom generation is the bottleneck on
  # most systems, not the storage. Useful only to see whether incompressible
  # data behaves differently from zeros, which matters on backends doing
  # inline compression or dedup. Kept small for that reason.
  dd_write_urandom)
    run_dd "$mp" dd_write_urandom "$DD_RAND_MB" \
      dd if=/dev/urandom of="$randfile" bs=1M count="$DD_RAND_MB" conv=fdatasync
    ;;

  # O_DIRECT bypasses the page cache. Without it you are mostly re-reading
  # RAM. If the filesystem rejects O_DIRECT, fall back and flag it.
  dd_read)
    if dd if="$zerofile" of=/dev/null bs=1M count=1 iflag=direct >/dev/null 2>&1; then
      run_dd "$mp" dd_read_direct "$DD_ZERO_MB" \
        dd if="$zerofile" of=/dev/null bs=1M count="$DD_ZERO_MB" iflag=direct
    else
      info "O_DIRECT unsupported here — reading through page cache (numbers will be inflated)"
      run_dd "$mp" dd_read_cached "$DD_ZERO_MB" \
        dd if="$zerofile" of=/dev/null bs=1M count="$DD_ZERO_MB"
    fi
    ;;

  seq_write_1m)
    run_fio "$mp" seq_write_1m \
      --name=seq_write_1m --filename=fio_seq.dat --rw=write --bs=1M \
      --size="$FIO_SIZE" --numjobs=1 --iodepth=16 --direct=1 \
      --ioengine="$IOENGINE" --runtime="$FIO_RUNTIME" --time_based
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

if [ "$ORDER" = "by-mount" ]; then
  first_mount=1
  for mp in "${USABLE[@]}"; do
    [ $first_mount -eq 0 ] && {
      log "cooldown between mounts"
      settle
    }
    first_mount=0
    log "$mp"
    for t in "${TESTS[@]}"; do
      run_test "$mp" "$t"
    done
  done
else
  first_unit=1
  for t in "${TESTS[@]}"; do
    log "$t"
    for mp in "${USABLE[@]}"; do
      [ $first_unit -eq 0 ] && settle
      first_unit=0
      info "-> $mp"
      run_test "$mp" "$t"
    done
  done
fi

ELAPSED=$(($(date +%s) - START_EPOCH))

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

FIO_TESTS=()
for t in "${TESTS[@]}"; do
  case "$t" in
  dd_* | pgbench) ;;
  *) FIO_TESTS+=("$t") ;;
  esac
done

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
  seq_read_1m)
    cat <<'EOF'
Streaming read bandwidth, reading back the file `seq_write_1m` just wrote. Same
shape as the write test, so the two are directly comparable; a backend that
reads much faster than it writes is usually acknowledging writes to a slower
durable tier, or replicating them.
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

# The gnuplot half of a chart, shared by the fio and pgbench plots so there is
# one place where the terminal, the axes and the legend are decided. Each part
# is a complete gnuplot `plot` element. Returns non-zero if given nothing.
render_plot() { # <img> <gp> <title> <xlabel> <ylabel> <logscale> <part>...
  local img="$1" gp="$2" desc="$3" xlabel="$4" ylabel="$5" logscale="$6"
  shift 6
  local parts=("$@")

  [ ${#parts[@]} -eq 0 ] && return 1

  local plotline
  plotline="$(
    IFS=,
    printf '%s' "${parts[*]}"
  )"

  # The legend sits below the plot, one entry per row, and the canvas grows to
  # make room for the rows. It used to sit outside right, which gnuplot sizes by
  # reserving space for the widest label — and the labels are mount paths. A
  # short one costs nothing, but a PVC mounted somewhere deep took the plot from
  # 917px of the 1100px canvas down to 245px, which is a tenth of the resolution
  # for the same number of samples. Below the plot, the label length stops
  # mattering: the same graph keeps ~1078px whatever the mounts are called.
  local height=$((420 + 24 * ${#parts[@]}))

  # Everything emitted below is deliberately ASCII: the script runs under
  # LC_ALL=C, where gnuplot's iconv cannot convert its own non-ASCII glyphs and
  # warns once per plot.
  {
    # svg rather than pngcairo: the SVG terminal is built into gnuplot and needs
    # no libraries at all, where pngcairo wants cairo, pango, glib, harfbuzz,
    # freetype, fontconfig and a font — ~55 MB of image to rasterise a line
    # chart the browser can draw itself. It also scales, which a 1100px PNG
    # did not.
    #
    # The font is named generically because the image no longer carries one;
    # whatever sans the viewer has is what the labels get. noenhanced: test
    # names and mount paths are full of underscores, which gnuplot's enhanced
    # text would render as subscripts. An explicit white background, because
    # the SVG terminal otherwise leaves it transparent and the black axis text
    # then disappears against a dark-mode page.
    echo "set terminal svg noenhanced size 1100,$height font 'sans-serif,10' background rgb 'white'"
    echo "set output '$img'"
    echo "set title '$desc'"
    echo "set xlabel '$xlabel'"
    echo "set ylabel '$ylabel'"
    echo "set grid xtics ytics lc rgb '#c8c8c8'"
    echo "set key below maxcols 1"
    echo "set xrange [0:*]"
    if [ "$logscale" = 1 ]; then
      echo "set logscale y"
      echo "set format y '%.0s%c'"
    else
      echo "set yrange [0:*]"
    fi
    echo "plot $plotline"
  } >"$gp"

  gnuplot "$gp" 2>>"$PLOTDIR/gnuplot.log"
  local rc=$?

  [ $rc -eq 0 ] && [ -s "$img" ]
}

# One SVG for one (test, metric), overlaying every mount and direction that
# produced samples. Returns non-zero if there was nothing to draw.
plot_metric() { # <test> <log-suffix> <key> <sum|avg> <scale> <ylabel> <title> <logscale>
  local test="$1" suffix="$2" key="$3" mode="$4" scale="$5"
  local ylabel="$6" desc="$7" logscale="$8"
  local parts=() mp sl d dat title

  for mp in "${USABLE[@]}"; do
    sl="$(slug "$mp")"
    for d in 0 1; do
      dat="$PLOTDATA/${sl}_${test}_${key}_${DDIR_NAME[$d]}.dat"
      # logscale doubles as the drop-non-positive flag: a zero is a real datum
      # on a throughput plot (the backend stalled) and must stay, but it has no
      # place on a log axis, where gnuplot would silently drop it anyway.
      fio_series "$LOGDIR/${sl}_${test}${suffix}" "$d" "$mode" "$scale" "$logscale" >"$dat"
      if [ ! -s "$dat" ]; then
        rm -f "$dat"
        continue
      fi
      if [ ${#USABLE[@]} -gt 1 ]; then
        title="$mp ${DDIR_NAME[$d]}"
      else
        title="${DDIR_NAME[$d]}"
      fi
      parts+=("'$dat' using 1:2 with lines lw 2 title '$title'")
    done
  done

  render_plot "$PLOTDIR/${test}_${key}.svg" "$PLOTDIR/${test}_${key}.gp" \
    "$desc - $test" "elapsed within the fio run (s)" "$ylabel" "$logscale" \
    "${parts[@]}"
}

# The pgbench counterpart: one metric, every mount on the same axes. There is
# no read/write split here — a TPC-B transaction is both.
plot_pgbench() { # <key> <tps|lat|maxlat> <ylabel> <title> <logscale>
  local key="$1" mode="$2" ylabel="$3" desc="$4" logscale="$5"
  local parts=() mp sl dat title

  for mp in "${USABLE[@]}"; do
    sl="$(slug "$mp")"
    dat="$PLOTDATA/${sl}_pgbench_${key}.dat"
    pgbench_series "$LOGDIR/pgbench_${sl}" "$mode" >"$dat"
    if [ ! -s "$dat" ]; then
      rm -f "$dat"
      continue
    fi
    if [ ${#USABLE[@]} -gt 1 ]; then title="$mp"; else title="pgbench"; fi
    parts+=("'$dat' using 1:2 with lines lw 2 title '$title'")
  done

  render_plot "$PLOTDIR/pgbench_${key}.svg" "$PLOTDIR/pgbench_${key}.gp" \
    "$desc - pgbench" "elapsed within the pgbench run (s)" "$ylabel" "$logscale" \
    "${parts[@]}"
}

pgbench_graphed=0

if [ "$have_gnuplot" = 1 ]; then
  log "Drawing graphs"
  for t in "${FIO_TESTS[@]}"; do
    drawn=0
    # bandwidth is logged in KiB/s; 1/1024 puts it in MiB/s.
    # clat is logged in nanoseconds; 1/1000 puts it in microseconds.
    plot_metric "$t" _iops.log iops sum 1 "IOPS" "IOPS over time" 0 && drawn=1
    plot_metric "$t" _bw.log bw sum 0.0009765625 "bandwidth (MiB/s)" \
      "Bandwidth over time" 0 && drawn=1
    plot_metric "$t" _clat.log clat avg 0.001 "completion latency (us)" \
      "Completion latency over time" 1 && drawn=1
    if [ $drawn -eq 1 ]; then info "$t"; else info "$t — no samples, skipped"; fi
  done

  if [ "$have_pgbench" = 1 ]; then
    drawn=0
    plot_pgbench tps tps "transactions/s" "Transaction rate over time" 0 && drawn=1
    plot_pgbench lat lat "mean latency (ms)" "Mean transaction latency over time" 1 && drawn=1
    # Worst case rather than mean, because the mean hides exactly what storage
    # does to a database: a checkpoint or an fsync stall shows up as one
    # interval where the slowest transaction took a hundred times the average.
    plot_pgbench maxlat maxlat "worst latency (ms)" \
      "Worst transaction latency over time" 1 && drawn=1
    pgbench_graphed=$drawn
    if [ $drawn -eq 1 ]; then info "pgbench"; else info "pgbench — no samples, skipped"; fi
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

log "Writing report"

{
  cat <<EOF
# Storage Benchmark Report

| Property | Value |
| -------- | ----- |
| Generated         | $(date -u '+%Y-%m-%d %H:%M:%S UTC') |
| Total runtime     | ${ELAPSED}s |
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
| Settle between runs   | ${SETTLE}s |
| dd zero write size    | ${DD_ZERO_MB} MiB |
| dd urandom write size | ${DD_RAND_MB} MiB |
| fio working set       | ${FIO_SIZE} |
| fio runtime per job   | ${FIO_RUNTIME}s |
| fio ioengine          | ${IOENGINE} |
| fio log sample window | ${LOG_AVG_MSEC}ms |
| pgbench               | $([ "$have_pgbench" = 1 ] && echo "scale ${PGBENCH_SCALE}, ${PGBENCH_CLIENTS} clients, ${PGBENCH_JOBS} threads, ${PGBENCH_TIME}s" || echo "not run") |

## Reading these numbers

* Run order was \`${ORDER}\`. In \`by-mount\` each mount gets an uninterrupted block of tests; in \`by-test\` the mounts are paired closely in time so shared backend load hits both about equally. If the two paths share physical hardware, \`by-test\` is the fairer head-to-head.
* A ${SETTLE}s idle period separates consecutive runs so the backend can finish flushing before the next measurement starts.
* What each fio job measures, and the exact command it ran, is in [fio tests](#fio-tests) — including the flags all of them share, such as \`--direct=1\` to keep the page cache out of the results. If you read one section before the numbers, read that one.
* The \`dd_write_urandom\` figure is **CPU-bound in most environments** — \`/dev/urandom\` generation, not the disk, is usually the limiting factor. Treat it as a check on how the backend handles incompressible data (relevant if it does inline compression or dedup), not as a throughput measurement.
* \`dd_read_direct\` bypasses the page cache. If it appears as \`dd_read_cached\` instead, the filesystem rejected O_DIRECT and that number is inflated by RAM caching.
* If you are comparing storage classes and only have time for one number, it is \`fsync_8k_qd1\` — or, if you would rather have one an application would recognise, the pgbench TPS in [pgbench](#pgbench).
* dd and fio measure the storage. [pgbench](#pgbench) measures what a database gets out of it, which is always less: the same commit that fio counts as one 8 KiB write is, in postgres, a WAL record, an fsync, a heap and index page to write back later, and a full-page image if a checkpoint has just been through. Where the two disagree about which mount is faster, pgbench is the one that resembles a workload.
* Latency columns are mean completion latency in microseconds. Bandwidth columns are KiB/s as reported by fio.
* The tables are whole-run averages. An average hides the shape of a run, and the shape is often the interesting part — a cache filling up, a throttle kicking in, a backend stalling. That is what the [time series](#over-time) section is for.

## Mount points

EOF

  for mp in "${USABLE[@]}"; do
    sl="$(slug "$mp")"
    echo "### $mp"
    echo
    echo '```text'
    cat "$RAWDIR/df_${sl}.txt" 2>/dev/null
    echo
    cat "$RAWDIR/mount_${sl}.txt" 2>/dev/null
    echo '```'
    echo
  done

  cat <<'MDEOF'
## dd results

Sequential, single-stream. Writes use `conv=fdatasync` so the data is committed
before dd reports its timing. Rows appear in execution order.

MDEOF

  csv_table "$DD_CSV"
  echo

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

The command shown under each test is the one that ran, recorded as it ran.

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
indexes), and then driven for ${PGBENCH_TIME}s through pgbench's built-in TPC-B-like
workload at ${PGBENCH_CLIENTS} concurrent clients across ${PGBENCH_JOBS} threads. Each transaction is
a handful of small updates and an insert, committed — so every one of them
costs a WAL write and an \`fsync\` before the client is told it succeeded.

That commit path is why this tracks \`fsync_8k_qd1\` more closely than any other
test here, and why the two can still disagree: postgres adds a WAL record, a
heap and index page the checkpointer has to write back later, and a full-page
image for the first write to each page after a checkpoint. Write amplification
of several times the logical change is normal, and a backend that does well on
raw \`fsync\` but badly here is usually one that copes with a steady trickle of
small writes but not with the burst a checkpoint delivers.

The cluster runs with \`fsync\`, \`synchronous_commit\` and \`full_page_writes\` all
on, which are the defaults, stated so that what was measured is on the record.
\`shared_buffers\` is left at its 128 MB default on purpose: a cluster large
enough to cache the working set would be reporting the speed of RAM. The
cluster is deleted after each mount.

| Column | Meaning |
| ------ | ------- |
| \`init_s\` | seconds to load the data — bulk write throughput, as pgbench timed it |
| \`tps\` | transactions per second over the timed run, excluding connection setup |
| \`latency_avg_ms\` | mean time to commit one transaction |
| \`failed\` | transactions rolled back; anything but 0 makes \`tps\` suspect |

EOF
    csv_table "$PG_CSV"
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

  # ---- time series ------------------------------------------------------
  cat <<EOF

## Over time

Every fio job also logs itself as a time series, one sample per
${LOG_AVG_MSEC}ms window. The x axis is elapsed time **within that job**, so runs
on different mounts line up even when they were minutes apart on the clock.

Where a job does both reads and writes (\`rand_rw_70_30_4k\`) each direction is
a separate line. Multi-job tests have their per-job samples summed for IOPS and
bandwidth and averaged for latency, so the lines are the aggregate the tables
report, not one worker's share of it. Latency uses a logarithmic y axis —
storage latency spans orders of magnitude and a linear axis flattens everything
below the worst spike into the baseline.

What to look for: a flat line is a backend holding its service level; a decaying
curve is usually a cache or write buffer filling; periodic collapses to near
zero are flush or compaction stalls, which a whole-run average will not show you
at all.

EOF

  graphed=0
  for t in "${FIO_TESTS[@]}"; do
    [ -f "$PLOTDIR/${t}_iops.svg" ] ||
      [ -f "$PLOTDIR/${t}_bw.svg" ] ||
      [ -f "$PLOTDIR/${t}_clat.svg" ] || continue
    graphed=1
    echo "### $t"
    echo
    for spec in "iops:IOPS" "bw:Bandwidth" "clat:Completion latency"; do
      key="${spec%%:*}"
      cap="${spec#*:}"
      [ -f "$PLOTDIR/${t}_${key}.svg" ] || continue
      # The alt text doubles as the caption: render_html lifts a paragraph that
      # holds nothing but an image into a <figure> and reuses it as the
      # <figcaption>, which is as close as Markdown gets to AsciiDoc's `.Title`.
      echo "![${cap} — ${t}](graphs/${t}_${key}.svg)"
      echo
    done
  done

  if [ "$pgbench_graphed" = 1 ]; then
    graphed=1
    echo "### pgbench"
    echo
    cat <<EOF
pgbench aggregates its own log into fixed intervals and one second is the
finest it will accept, so these are coarser than the fio graphs above — a stall
shorter than a second is inside a sample rather than visible as one. The worst
latency chart is the one to read for that: it plots the slowest single
transaction in each interval, so a checkpoint or an fsync stall that the mean
absorbs still shows as a spike.

EOF
    for spec in "tps:Transaction rate" "lat:Mean latency" "maxlat:Worst latency"; do
      key="${spec%%:*}"
      cap="${spec#*:}"
      [ -f "$PLOTDIR/pgbench_${key}.svg" ] || continue
      echo "![${cap} — pgbench](graphs/pgbench_${key}.svg)"
      echo
    done
  fi

  if [ "$graphed" = 0 ]; then
    if [ "$have_gnuplot" = 1 ]; then
      echo "No time-series samples were produced — every fio job failed, or the"
      echo "runs were shorter than one ${LOG_AVG_MSEC}ms sample window."
    else
      echo "Graphs were skipped: gnuplot is not available in this image, or"
      echo "\`PLOT=0\` was set. The underlying logs are still under \`fio-logs/\`"
      echo "and can be plotted after the fact."
    fi
    echo
  fi

  cat <<'MDEOF'
## Raw output

Unparsed dd output and fio terse lines are archived under `raw/`, one file per
test per mount. The fio files are terse version 3 records — useful if you want
latency percentiles or bandwidth min/max, which are not carried into the CSV
above.

`raw/pgbench_<mount>.txt` holds everything pgbench and initdb printed, and
`raw/pgbench_<mount>_server.log` the postgres server log for that mount —
checkpoint and autovacuum activity land there, which is usually where an
unexplained dip in the transaction rate is explained.

`fio-logs/` holds fio's own time-series logs, named
`<mount>_<test>_{bw,iops,lat,slat,clat}.log`, in fio's usual
`time_ms, value, ddir, blocksize, offset` format (`ddir` 0 = read, 1 = write).
Bandwidth is KiB/s, latency is nanoseconds. Alongside them are pgbench's
aggregate logs, `pgbench_<mount>.<pid>[.<thread>]`, one row per second per
thread as `interval_start num_transactions sum_latency sum_latency_2
min_latency max_latency` with latencies in microseconds.

These are the unprocessed inputs to
the graphs above, and the fio ones are in fio's standard log format, so `fio2gnuplot`
and `fiologparser.py` will read them if you want to re-plot them differently.
Neither ships in this image — both are Python, and CPython is most of what a
benchmark image would otherwise carry.

`graphs/` holds the rendered SVGs alongside the gnuplot script and the reduced
data files that produced each one, so any plot can be tweaked and redrawn
without re-running the benchmark:

```console
$ gnuplot graphs/rand_read_4k_iops.gp
```
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
# graph is inlined as a data: URI, so the HTML can be mailed or copied out of a
# pod on its own without dragging graphs/ along with it.
# ---------------------------------------------------------------------------

# The page shell. Light and dark are both styled because this is read in a
# browser, but graph figures keep a white plate in either: the SVGs gnuplot
# writes have a hard-coded white background (see plot_metric) and black axis
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
figure img {
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
decorate() { # <data-uri map>
  awk -v mapfile="$1" '
    BEGIN {
      while ((getline ln < mapfile) > 0) {
        i = index(ln, "\t")
        if (i > 0) uri[substr(ln, 1, i - 1)] = substr(ln, i + 1)
      }
      close(mapfile)
    }

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
    function inline_uris(s,   k) {
      if (!index(s, "src=\"graphs/")) return s
      for (k in uri) gsub("src=\"" k "\"", "src=\"" uri[k] "\"", s)
      return s
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
        # figure, with the alt text serving as the caption.
        if (l ~ /^<p><img [^>]*\/><\/p>$/) {
          img = l
          sub(/^<p>/, "", img)
          sub(/<\/p>$/, "", img)
          alt = ""
          if (match(img, /alt="[^"]*"/))
            alt = substr(img, RSTART + 5, RLENGTH - 6)
          print "<figure>" inline_uris(img) \
            (alt == "" ? "" : "<figcaption>" alt "</figcaption>") "</figure>"
          continue
        }

        # Wide tables (fio results is eight columns) scroll inside their own
        # box rather than pushing the page sideways.
        if (l == "<table>") { print "<div class=\"tablewrap\">"; print l; continue }
        if (l == "</table>") { print l; print "</div>"; continue }

        print inline_uris(l)
      }
      print "</main>"
    }
  '
}

render_html() { # <markdown> <html out>
  local md="$1" out="$2"
  local map="$RAWDIR/graph-data-uri.map" f rc

  # base64 rather than inlining the SVG markup: gnuplot gives every plot the
  # same element ids, and a dozen inline <svg> blocks sharing one id space would
  # have each of them resolve its <defs> references to the first plot on the
  # page. A data: URI keeps each graph in its own document, as a separate file
  # would have.
  : >"$map"
  for f in "$PLOTDIR"/*.svg; do
    [ -f "$f" ] || continue
    printf '%s\t%s\n' "graphs/${f##*/}" \
      "data:image/svg+xml;base64,$(base64 -w0 "$f")" >>"$map"
  done

  {
    html_head
    cmark-gfm --unsafe -e table -e autolink "$md" | decorate "$map"
    html_foot
  } >"$out"
  rc=$?

  rm -f "$map"
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

echo
echo "Done in ${ELAPSED}s."
echo "  Report   : $MD"
[ -n "$HTML" ] && echo "             $HTML"
echo "  CSVs     : $DD_CSV"
echo "             $FIO_CSV"
[ "$have_pgbench" = 1 ] && echo "             $PG_CSV"
if [ "$have_gnuplot" = 1 ]; then
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
