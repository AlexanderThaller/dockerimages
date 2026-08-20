#!/usr/bin/env bash
#
# storage-bench.sh — dd + fio benchmark across one or more mounted PVCs,
#                    emitting CSV data files and an AsciiDoctor report.
#
# Usage:
#   ./storage-bench.sh /data/ceph /data/portworx
#   ORDER=by-test ./storage-bench.sh /data/ceph /data/portworx
#
# The graphs need gnuplot and the rendered report needs asciidoctor, neither of
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
#   LOG_AVG_MSEC  fio time-series sample window (default 500)
#   PLOT          1|0, draw the gnuplot graphs  (default 1)
#   RENDER        html|none                     (default html)
#
# Runs unprivileged — no root, no SCC changes needed.

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
LOG_AVG_MSEC="${LOG_AVG_MSEC:-500}"
PLOT="${PLOT:-1}"
RENDER="${RENDER:-html}"

case "$ORDER" in
by-mount | by-test) ;;
*)
  echo "ORDER must be 'by-mount' or 'by-test' (got '$ORDER')" >&2
  exit 1
  ;;
esac

# The sample window doubles as the bucket width when the per-job samples are
# folded together, so it has to be a positive integer.
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

# HTML only. A PDF would mean asciidoctor-pdf, and that gem pulls prawn, a PDF
# reader and a syntax highlighter that shells out to CPython — roughly a fifth
# of the image for an output format nobody was reading. The .adoc is kept next
# to the HTML, so `asciidoctor-pdf` on any host that has it still gets you one.
case "$RENDER" in
html | none) ;;
*)
  echo "RENDER must be one of html|none (got '$RENDER')" >&2
  exit 1
  ;;
esac

DD_CSV="$OUTDIR/dd_results.csv"
FIO_CSV="$OUTDIR/fio_results.csv"
ADOC="$OUTDIR/storage-benchmark-report.adoc"
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
)

CREATED=()
cleanup() {
  echo
  echo "Cleaning up test files..."
  for f in "${CREATED[@]:-}"; do [ -n "$f" ] && rm -f "$f"; done
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

if [ "$RENDER" != "none" ] && ! command -v asciidoctor >/dev/null 2>&1; then
  echo "NOTE asciidoctor not found in PATH — report stays as .adoc source" >&2
  MISSING+=("asciidoctor — the report was not rendered")
  RENDER=none
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
  dd_*) ;;
  *) FIO_TESTS+=("$t") ;;
  esac
done

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

# One SVG for one (test, metric), overlaying every mount and direction that
# produced samples. Returns non-zero if there was nothing to draw.
plot_metric() { # <test> <log-suffix> <key> <sum|avg> <scale> <ylabel> <title> <logscale>
  local test="$1" suffix="$2" key="$3" mode="$4" scale="$5"
  local ylabel="$6" desc="$7" logscale="$8"
  local img="$PLOTDIR/${test}_${key}.svg"
  local gp="$PLOTDIR/${test}_${key}.gp"
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

  [ ${#parts[@]} -eq 0 ] && return 1

  local plotline
  plotline="$(
    IFS=,
    printf '%s' "${parts[*]}"
  )"

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
    echo "set terminal svg noenhanced size 1100,420 font 'sans-serif,10' background rgb 'white'"
    echo "set output '$img'"
    echo "set title '$desc - $test'"
    echo "set xlabel 'elapsed within the fio run (s)'"
    echo "set ylabel '$ylabel'"
    echo "set grid xtics ytics lc rgb '#c8c8c8'"
    echo "set key outside right top"
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
fi

# ---------------------------------------------------------------------------
# AsciiDoctor report
# ---------------------------------------------------------------------------
log "Writing report"

{
  cat <<EOF
= Storage Benchmark Report
:toc: left
:toclevels: 2
:icons: font
:sectnums:
:revdate: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

[cols="1,3"]
|===
|Generated    |$(date -u '+%Y-%m-%d %H:%M:%S UTC')
|Total runtime|${ELAPSED}s
|Host / pod   |$(uname -n)
|Kernel       |$(uname -r)
|Running as   |uid $(id -u), gid $(id -g)
|fio version  |$(fio --version 2>/dev/null)
|Mounts under test |${USABLE[*]}
|Run order    |$ORDER
|===

== Test parameters

[cols="1,1"]
|===
|Parameter |Value

|Run order             |${ORDER}
|Settle between runs   |${SETTLE}s
|dd zero write size    |${DD_ZERO_MB} MiB
|dd urandom write size |${DD_RAND_MB} MiB
|fio working set       |${FIO_SIZE}
|fio runtime per job   |${FIO_RUNTIME}s
|fio ioengine          |${IOENGINE}
|fio log sample window |${LOG_AVG_MSEC}ms
|===

== Reading these numbers

* Run order was \`${ORDER}\`. In \`by-mount\` each mount gets an uninterrupted block of tests; in \`by-test\` the mounts are paired closely in time so shared backend load hits both about equally. If the two paths share physical hardware, \`by-test\` is the fairer head-to-head.
* A ${SETTLE}s idle period separates consecutive runs so the backend can finish flushing before the next measurement starts.
* All fio jobs use \`--direct=1\` so results reflect the storage backend rather than the page cache.
* The \`dd_write_urandom\` figure is *CPU-bound in most environments* — \`/dev/urandom\` generation, not the disk, is usually the limiting factor. Treat it as a check on how the backend handles incompressible data (relevant if it does inline compression or dedup), not as a throughput measurement.
* \`dd_read_direct\` bypasses the page cache. If it appears as \`dd_read_cached\` instead, the filesystem rejected O_DIRECT and that number is inflated by RAM caching.
* \`fsync_8k_qd1\` is queue-depth 1 with an fsync per write. This is the closest proxy for database commit latency and is usually the number that separates storage classes in practice.
* Latency columns are mean completion latency in microseconds. Bandwidth columns are KiB/s as reported by fio.
* The tables are whole-run averages. An average hides the shape of a run, and the shape is often the interesting part — a cache filling up, a throttle kicking in, a backend stalling. That is what the <<over-time,time series>> section is for.

== Mount points

EOF

  for mp in "${USABLE[@]}"; do
    sl="$(slug "$mp")"
    echo "=== $mp"
    echo
    echo "[source,text]"
    echo "----"
    cat "$RAWDIR/df_${sl}.txt" 2>/dev/null
    echo
    cat "$RAWDIR/mount_${sl}.txt" 2>/dev/null
    echo "----"
    echo
  done

  cat <<'ADOCEOF'
== dd results

Sequential, single-stream. Writes use `conv=fdatasync` so the data is committed
before dd reports its timing. Rows appear in execution order.

[format=csv,options="header",cols="2,2,1,1,1"]
|===
include::dd_results.csv[]
|===

== fio results

Rows appear in execution order.

[format=csv,options="header"]
|===
include::fio_results.csv[]
|===
ADOCEOF

  # ---- time series ------------------------------------------------------
  cat <<EOF

[#over-time]
== Over time

Every fio job also logs itself as a time series, one sample per
${LOG_AVG_MSEC}ms window. The x axis is elapsed time *within that job*, so runs
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
    echo "=== $t"
    echo
    for spec in "iops:IOPS" "bw:Bandwidth" "clat:Completion latency"; do
      key="${spec%%:*}"
      cap="${spec#*:}"
      [ -f "$PLOTDIR/${t}_${key}.svg" ] || continue
      echo ".${cap} — ${t}"
      echo "image::graphs/${t}_${key}.svg[\"${cap} over time, ${t}\",align=\"center\"]"
      echo
    done
  done

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

  cat <<'ADOCEOF'
== Raw output

Unparsed dd output and fio terse lines are archived under `raw/`, one file per
test per mount. The fio files are terse version 3 records — useful if you want
latency percentiles or bandwidth min/max, which are not carried into the CSV
above.

`fio-logs/` holds fio's own time-series logs, named
`<mount>_<test>_{bw,iops,lat,slat,clat}.log`, in fio's usual
`time_ms, value, ddir, blocksize, offset` format (`ddir` 0 = read, 1 = write).
Bandwidth is KiB/s, latency is nanoseconds. These are the unprocessed inputs to
the graphs above, and they are in fio's standard log format, so `fio2gnuplot`
and `fiologparser.py` will read them if you want to re-plot them differently.
Neither ships in this image — both are Python, and CPython is most of what a
benchmark image would otherwise carry.

`graphs/` holds the rendered SVGs alongside the gnuplot script and the reduced
data files that produced each one, so any plot can be tweaked and redrawn
without re-running the benchmark:

[source,console]
----
$ gnuplot graphs/rand_read_4k_iops.gp
----
ADOCEOF
} >"$ADOC"

# ---------------------------------------------------------------------------
# Render
#
# -a data-uri inlines the SVGs, which makes the HTML a single file you can mail
# or copy out of a pod without dragging graphs/ along with it.
# ---------------------------------------------------------------------------
HTML=""

if [ "$RENDER" = "html" ]; then
  log "Rendering report"
  info "HTML ..."
  html_out="$OUTDIR/storage-benchmark-report.html"
  if asciidoctor -a data-uri -o "$html_out" "$ADOC" >"$RAWDIR/asciidoctor.log" 2>&1 &&
    [ -s "$html_out" ]; then
    HTML="$html_out"
  else
    info "  FAILED (see $RAWDIR/asciidoctor.log)"
  fi
fi

echo
echo "Done in ${ELAPSED}s."
echo "  Report   : $ADOC"
[ -n "$HTML" ] && echo "             $HTML"
echo "  CSVs     : $DD_CSV"
echo "             $FIO_CSV"
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
  echo "Render with:"
  echo "  asciidoctor -a data-uri $ADOC       # -> single-file HTML"
  echo "  asciidoctor-pdf $ADOC               # -> PDF, needs asciidoctor-pdf"
fi
