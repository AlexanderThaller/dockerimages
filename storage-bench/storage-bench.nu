#!/usr/bin/env nu
#
# storage-bench.nu — a line-for-line-in-spirit translation of storage-bench.sh
#                    into Nushell, kept next to it so the two can be compared.
#
# NOT WHAT SHIPS. The image builds storage-bench.sh; nothing builds this. It is
# here as a comparison — the same program in a language with types, so that
# "should this be Nushell" is a question with evidence behind it rather than an
# argument. The verdict, and the measurements behind it, are at the bottom of
# this header.
#
# It is the same benchmark: fio + pgbench across one or more mounted PVCs,
# emitting CSV data files and a Markdown report. Everything the shell version
# documents about *what* is measured and *why* applies here unchanged, so that
# prose is not repeated — read storage-bench.sh for it. What follows is only
# what is different about this implementation.
#
# Two of the differences did not stay differences: the dd tests became fio jobs
# and the /proc/mounts lookup learned to find the filesystem a path is *on*.
# Both were worth having in the version that ships, so both are in
# storage-bench.sh now and this file is no longer alone in doing them.
#
# To run it, since no image will:
#   nix-shell -p nushell --run 'nu storage-bench.nu /tank/backup'
#
# Usage:
#   nu storage-bench.nu /data/ceph /data/portworx
#   ORDER=by-test nu storage-bench.nu /data/ceph /data/portworx
#
# Tunables are the same environment variables, with the same defaults:
#   OUTBASE RUNDIR ORDER REPEATS SETTLE TEST_SETTLE FIO_SIZE FIO_RUNTIME
#   IOENGINE LOG_AVG_MSEC PGBENCH PGBENCH_SCALE PGBENCH_CLIENTS PGBENCH_JOBS
#   PGBENCH_TIME PGBENCH_WARMUP PGBENCH_MODE PGBENCH_MAX_WAL PLOT RENDER
#   ARCHIVE
#
# DD_ZERO_MB and DD_RAND_MB are gone with the dd tests they sized; see below.
#
# ---------------------------------------------------------------------------
# What the two versions do differently, and why
# ---------------------------------------------------------------------------
#
# * No awk, no sed, no cut, no sort. Every text-munging pass in the shell
#   version — parsing fio's terse line, folding fio's time-series logs into
#   buckets, averaging passes together, turning a CSV into a Markdown table —
#   is a pipeline over structured data here. The five awk programs are gone;
#   the two that were doing real work (fio_series, pgbench_series) became
#   `group-by` + `math sum/avg`, and csv_table became `to md`.
#
# * No globals. The shell version accumulates state in globals that functions
#   reach out and touch — FIO_ARGS, CREATED, PG_DATADIRS, RUN_IDS, MISSING,
#   PLOT_PARTS. Nushell closures cannot mutate anything they captured, so all of
#   that is either returned by the function that computes it or precomputed once
#   and threaded through as `ctx`. PLOT_PARTS in particular existed only because
#   a bash function cannot return a list; here it is a return value.
#
# * Results are a table, not a file being appended to. Rows are collected as
#   records and written with `to csv` at the end — and *also* appended as they
#   are produced, because a benchmark that runs for an hour should not lose
#   everything if it dies in the fifty-ninth minute. That is the one place this
#   keeps a shell habit deliberately.
#
# * No trap. Nushell has no signal handling, so the cleanup that the shell
#   version wires to EXIT/INT/TERM runs here on the normal path and on an error
#   (via try/catch) but *not* on Ctrl-C. A postmaster started on a mount and
#   interrupted will therefore outlive the run. This is the one genuine
#   regression in the translation; `pg_ctl -D <mount>/pgdata -m immediate stop`
#   cleans up after it. Everything else the trap did — removing dd/fio scratch
#   files, dropping the pgdata clusters — is idempotent and happens on the way
#   out.
#
# * Errors are values, not exit codes. Every external is run through
#   `| complete`, which yields a record of stdout, stderr and exit_code, so
#   there is no `$?`, no `2>&1` into a variable, and stderr does not have to be
#   folded into stdout to be captured.
#
# * Numbers are numbers. `$f.7 | into float` fails loudly on a field fio did not
#   produce, where `awk '{print $8}'` silently prints an empty column into the
#   CSV.
#
# * No dd, and no coreutils behind it. The three dd tests are two fio jobs (see
#   `fio-job-args`), and the four remaining coreutils callers — `df`, `id`,
#   `uname`, `mktemp` — are `sys disks`, /proc and a builtin. Nothing outside
#   fio, gnuplot, cmark-gfm and postgres is executed, so the image needs no
#   shell utilities at all.
#
# ---------------------------------------------------------------------------
# What it costs the image
# ---------------------------------------------------------------------------
#
# More, which is the short answer to why this is not what ships.
#
# Dropping dd and the four coreutils callers would take bash, coreutils, gawk,
# gnused and gnugrep out of runtime-deps.nix entirely — nothing left but fio,
# gnuplot, cmark-gfm and postgresql. Measured against the pinned nixpkgs, as
# closure size, with both images actually built and loaded:
#
#   fio + gnuplot + cmark-gfm + postgresql                  99.8 MiB
#   ... + bash + coreutils + gawk + gnused + gnugrep       116.8 MiB   (the shell version)
#   ... + nushell, keeping coreutils                       163.9 MiB
#   ... + nushell, coreutils dropped                       154.0 MiB
#   ... + nushell built without default features           136.6 MiB   (this version)
#
# and as images, both built and loaded into docker: 131 MB against 151 MB
# uncompressed, 42 MB against 49 MB as a tarball.
#
# The whole POSIX toolchain the shell version leans on costs 17 MiB. Stock
# nushell costs 54 MiB on its own, so removing every last thing it could
# replace still left the image a third larger. Most of that is optional: the
# default build carries a bundled SQLite, plugin support and trash-support that
# nothing here touches, and
#
#   pkgs.nushell.override { withDefaultFeatures = false; }
#
# is a 37 MB binary rather than a 55 MB one and still has `which`, `sys disks`
# and `mktemp`, which is all this script asks of it. That is the last column
# above, and it is +20 MiB against the shell version rather than +47.
#
# One thing that build does need back: a /bin/sh. Not for this script — for
# initdb, which checks the `postgres` binary next to it through system(3), and
# system(3) is /bin/sh by definition. Without one initdb stops at "program
# \"postgres\" is needed by initdb but was not found", naming the one file that
# is definitely present. dash covers it in about a megabyte.
#
# ---------------------------------------------------------------------------
# The verdict
# ---------------------------------------------------------------------------
#
# Overkill, for this program, and the line counts say so before the sizes do:
# 1476 non-comment lines here against 1332 there, for a suite with fewer tests.
# Narrowed to the part that should favour Nushell most — the three series
# reductions and the CSV-to-table rendering — it is 84 lines against 85. A wash.
#
# The reason is that Nushell pays off when data stays structured end to end,
# and here it cannot: the reduction's output is a .dat file for gnuplot and a
# .gp script beside it. Text in, records, text out, and only the middle gets
# better — `save-series` exists purely to undo the structure the reduction just
# built, where awk never needed it because it was writing text all along. awk
# was already at the right altitude for this job.
#
# What is genuinely better here: `| complete` instead of `$?` and `2>&1` into a
# variable; FIO_ARGS as an input rather than a global filled as a side effect;
# `$f | get 48` failing loudly where `awk '{print $49}'` writes an empty column;
# and `to md`, which deleted 19 lines of awk outright.
#
# What is worse, and structural: no signal trap at all, on a program that
# starts a postmaster on someone's storage. `str downcase` renamed between
# 0.112 and 0.114, on a script pinned in an image and touched twice a year. Raw
# strings that will not parse if the first character is `#`, and interpolated
# strings needing `\(` — which silently ate a link out of the report until the
# diff against the shell version caught it. Quoting bugs that produce wrong
# output rather than an error are exactly what heredocs do not do.
#
# Where the answer would change: if this grew analysis rather than
# orchestration — percentiles out of the terse records, a run compared against
# a stored baseline, regressions flagged across runs — because that work stays
# structured and never has to become text again.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Tests in execution order. Read tests depend on the write test that precedes
# them, so this order matters in both ORDER modes.
const TESTS = [
  seq_write_1m
  seq_write_zero_1m
  seq_write_rand_1m
  seq_read_1m
  rand_write_4k
  rand_read_4k
  rand_rw_70_30_4k
  fsync_8k_qd1
  pgbench
]

const DDIR_NAME = [read write]

# gnuplot picks its own colours per plot element, which is fine when every
# element is a line. The aggregates pair a band with a line and the two have to
# match, so the colour is stated instead. These are gnuplot's own defaults,
# which are already chosen to stay distinguishable.
const PLOT_COLORS = [
  '#9400d3' '#009e73' '#56b4e9' '#e69f00'
  '#f0e442' '#0072b2' '#e51e10' '#000000'
]

# pgbench aggregates its own log into fixed intervals and one second is the
# finest it accepts, so unlike LOG_AVG_MSEC this is not a tunable — it is the
# floor. It is named here because the report quotes it and pgbench-series
# divides by it.
const PGBENCH_AGG_INTERVAL = 1

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def log-section [msg: string] { print $"\n=== ($msg) ===" }
def info [msg: string] { print $"  ($msg)" }

def slug [p: string]: nothing -> string {
  $p | str replace --regex '^/' '' | str replace --all '/' '_'
}

def settle [cfg: record] {
  if $cfg.settle > 0 {
    info $"settling ($cfg.settle)s..."
    sleep ($cfg.settle * 1sec)
  }
}

# Quieter than settle: it runs between every pair of tests, so announcing itself
# each time would bury the results it sits between.
def test-settle [cfg: record] {
  if $cfg.test_settle > 0 {
    sleep ($cfg.test_settle * 1sec)
  }
}

def run-id-for [n: int]: nothing -> string {
  $"run-($n | fill --alignment right --character '0' --width 2)"
}

def has-cmd [name: string]: nothing -> bool { (which $name | is-not-empty) }

# ---------------------------------------------------------------------------
# The four things coreutils was still here for
#
# `id -u`, `id -g`, `uname -n`, `uname -r` and `mktemp -d` were the whole of
# what the shell version needed coreutils for once dd went — five calls, each
# of them one number or one string, each of them costing a fork and a parse of
# the output. All five are readable from /proc or answered by a builtin, and
# between them and the dd rewrite the image needs no shell utilities at all.
#
# /proc rather than `sys host`: in a container `sys host` reports what the
# kernel says, which is the host's, while /proc/self is namespaced and is
# therefore the answer to the question actually being asked — which uid is this
# process, on this machine, as this machine sees itself.
# ---------------------------------------------------------------------------

# /proc/self/status carries `Uid:` and `Gid:` as four tab-separated values —
# real, effective, saved and filesystem. The effective one is the second, and
# it is the one that decides whether a write lands and whether postgres will
# start.
def proc-id [field: string]: nothing -> int {
  open /proc/self/status
  | lines
  | where {|l| $l starts-with $"($field):" }
  | first
  | split row --regex '\s+'
  | get 2
  | into int
}

def uid []: nothing -> int { proc-id "Uid" }
def gid []: nothing -> int { proc-id "Gid" }
def hostname []: nothing -> string { open /proc/sys/kernel/hostname | str trim }
def kernel-release []: nothing -> string { open /proc/sys/kernel/osrelease | str trim }

# `df -h`, without df, as a one-row table.
#
# Two sources, because neither is enough on its own. /proc/mounts has the
# device and the filesystem type for every mount there is, and no capacity at
# all — the kernel does not put statvfs in a file. `sys disks` has the capacity,
# because it calls statvfs, but it only lists what sysinfo considers a real
# disk: a tmpfs, and some network filesystems, are simply not in it. So the
# identity always comes from /proc/mounts and the capacity is filled in when it
# is known and left as `unknown` when it is not, which is the honest answer and
# is what the `--tmpfs` mounts under `just smoke` will show. The mount line
# printed directly under the table usually still answers it there — a tmpfs
# carries its `size=` in its mount options.
#
# A real PVC is a real filesystem on a real device and is listed, so the case
# that loses information is the test harness rather than the thing being
# measured.
#
# The filesystem a path is on is the longest mount point that prefixes it —
# the same rule df applies, and the reason a PVC mounted at /data/ceph is not
# reported as whatever / happens to be.
def owning-mount [mp: string]: nothing -> record {
  open --raw /proc/mounts
  | lines
  | each {|l| { line: $l, f: ($l | split row ' ') } }
  | where {|m| ($m.f | length) >= 3 }
  | each {|m| { device: $m.f.0, mount: $m.f.1, fstype: $m.f.2, line: $m.line } }
  | where {|m| $mp == $m.mount or ($mp | str starts-with (if $m.mount == "/" { "/" } else { $"($m.mount)/" })) }
  | sort-by {|m| $m.mount | str length }
  | last
}

def capacity-of [owner: record]: nothing -> table {
  let disk = (sys disks | where mount == $owner.mount | get --optional 0)

  {
    Filesystem: $owner.device
    Type: $owner.fstype
    "Mounted on": $owner.mount
    Size: (if $disk == null { "unknown" } else { $"($disk.total)" })
    Used: (if $disk == null { "unknown" } else { $"($disk.total - $disk.free)" })
    Avail: (if $disk == null { "unknown" } else { $"($disk.free)" })
    "Use%": (if $disk == null or $disk.total == 0b { "unknown" } else {
      $"(((($disk.total - $disk.free) / $disk.total) * 100) | math round --precision 1)%"
    })
  }
  | wrap-row
}

# `to md` wants a table; a bare record renders as a two-column key/value list
# instead. One place that says so.
def wrap-row []: record -> table { [$in] }

def file-has-content [f: path]: nothing -> bool {
  if not ($f | path exists) { return false }
  (ls $f | get 0.size) > 0b
}

# `| complete` gives stdout and stderr separately; most of the parsing here
# wants whatever the tool said, wherever it said it.
def merged [res: record]: nothing -> string { $"($res.stdout)($res.stderr)" }

# The last line matching a regex with one capture group, or null. Replaces the
# `sed -n 's/.../\1/p' | tail -1` idiom, which appears six times in the shell
# version.
def last-capture [text: string, re: string]: nothing -> any {
  let hits = ($text | lines | parse --regex $re)
  if ($hits | is-empty) { null } else { $hits | last | get capture0 }
}

# ---------------------------------------------------------------------------
# Configuration
#
# The shell version validates each tunable where it happens to be used, in four
# separate places and two different styles. Here every tunable is read,
# defaulted, type-checked and range-checked in one function, which then hands
# back a record that nothing else has to re-validate.
# ---------------------------------------------------------------------------

def env-int [name: string, fallback: int, min: int = 1]: nothing -> int {
  let raw = ($env | get --optional $name)
  if $raw == null { return $fallback }
  if not ($raw =~ '^[0-9]+$') {
    error make --unspanned { msg: $"($name) must be a positive integer \(got '($raw)')" }
  }
  let v = ($raw | into int)
  if $v < $min {
    error make --unspanned { msg: $"($name) must be >= ($min) \(got '($raw)')" }
  }
  $v
}

def env-str [name: string, fallback: string]: nothing -> string {
  $env | get --optional $name | default $fallback
}

def env-choice [name: string, fallback: string, allowed: list<string>]: nothing -> string {
  let v = (env-str $name $fallback)
  if not ($v in $allowed) {
    error make --unspanned {
      msg: $"($name) must be one of ($allowed | str join '|') \(got '($v)')"
    }
  }
  $v
}

def load-config [ts: string]: nothing -> record {
  # Where the results go, in two parts, so that pointing the benchmark at a
  # mounted volume does not also flatten every run into the same directory. The
  # volume is OUTBASE and stays put; RUNDIR is per-run and carries the
  # timestamp, so consecutive runs sit side by side instead of overwriting each
  # other. OUTDIR is still read, as the base, because that is the variable
  # callers were passing the volume in before this was split. Setting RUNDIR
  # empty restores the flat behaviour.
  let outbase = (env-str "OUTBASE" (env-str "OUTDIR" "/tmp"))
  let rundir = ($env | get --optional RUNDIR | default $"bench-results-($ts)")
  let outdir = (if ($rundir | is-empty) { $outbase } else { $"($outbase)/($rundir)" })

  let cfg = {
    outdir: $outdir
    # Kept so the archive step can tell a named run directory, which it can put
    # the tarball beside, from an empty RUNDIR, where the run directory is
    # OUTBASE itself and there is no beside.
    rundir: $rundir
    order: (env-choice "ORDER" "by-mount" [by-mount by-test])
    repeats: (env-int "REPEATS" 3)
    # SETTLE alone may be zero: that is how the cooldown is turned off.
    settle: (env-int "SETTLE" 15 0)
    # The short pause between consecutive tests on one mount. SETTLE is the long
    # cooldown between whole runs; this is the small one between the jobs inside
    # a run, where there used to be no gap at all. A test that ends with dirty
    # pages still being written back would otherwise have that writeback land
    # inside the first samples of the test after it. One second drains what a
    # fio job leaves behind; it is not enough to let a backend recover, which is
    # what SETTLE is for.
    test_settle: (env-int "TEST_SETTLE" 1 0)
    fio_size: (env-str "FIO_SIZE" "10G")
    fio_runtime: (env-int "FIO_RUNTIME" 60)
    ioengine: (env-str "IOENGINE" "libaio")
    # The sample window doubles as the bucket width when the per-job samples
    # are folded together, so it has to be a positive integer. 100ms is a floor
    # worth thinking before going under — see the shell version for why.
    log_avg_msec: (env-int "LOG_AVG_MSEC" 100)
    pgbench: ((env-str "PGBENCH" "1") == "1")
    pgbench_scale: (env-int "PGBENCH_SCALE" 100)
    pgbench_clients: (env-int "PGBENCH_CLIENTS" 8)
    pgbench_jobs: (env-int "PGBENCH_JOBS" 4)
    pgbench_time: (env-int "PGBENCH_TIME" 300)
    # An unmeasured run before the measured one. Measured from cold, pgbench
    # reports the decay into the workload rather than the workload: empty
    # buffer cache, WAL not yet wrapped, no checkpoint behind it. Zero is
    # allowed, and is how you ask to measure from cold deliberately.
    pgbench_warmup: (env-int "PGBENCH_WARMUP" 30 0)
    # pgbench's default is `simple`, which has the server parse and plan every
    # statement again on each execution — at which point a good part of what is
    # measured is postgres reading SQL rather than the storage under it. Real
    # applications and every connection pooler use prepared statements.
    pgbench_mode: (env-choice "PGBENCH_MODE" "prepared" [simple extended prepared])
    # postgres checkpoints when max_wal_size is reached, and at the 1 GB default
    # a mount that absorbs writes quickly checkpoints every few seconds — a
    # property of the default rather than of any tuned database, and it
    # dominates the run.
    pgbench_max_wal: (env-str "PGBENCH_MAX_WAL" "4GB")
    plot: ((env-str "PLOT" "1") == "1")
    # HTML only. Anything else — PDF, DOCX — means pandoc, and pandoc is a
    # Haskell binary several times the size of everything else in this image put
    # together, for output formats nobody was reading.
    render: (env-choice "RENDER" "html" [html none])
    # Tar the finished run directory up, so what has to be copied off the
    # machine that was measured is one file rather than a few thousand.
    archive: ((env-str "ARCHIVE" "1") == "1")
  }

  # pgbench divides its clients between its threads and refuses the run outright
  # if the division leaves a thread with none. Checked up front rather than left
  # to pgbench, which would otherwise fail an hour into the run, after dd and
  # fio have already been paid for.
  if $cfg.pgbench_jobs > $cfg.pgbench_clients {
    error make --unspanned {
      msg: $"PGBENCH_JOBS \(($cfg.pgbench_jobs)) cannot exceed PGBENCH_CLIENTS \(($cfg.pgbench_clients))"
    }
  }

  $cfg
}

# Every fio job's flags, derived from the config once. The shell version fills
# a global associative array as each job runs, purely so the report can quote
# what ran; here the same table is the *input* to running them, so the report
# and the run cannot disagree.
#
# The two `_zero_` and `_rand_` jobs are what became of dd. dd was doing three
# things here: a 1 MiB-block sequential write of zeros, the same write of
# /dev/urandom, and a sequential read back with O_DIRECT. The read is
# `seq_read_1m` and always was — same block size, same direction, and O_DIRECT
# rather than dd's fallback to the page cache. What the pair of writes measured
# that no fio job did is what the backend does with the *content*: zeros
# compress and dedupe, urandom does neither, and the gap between them is the
# only signal in the suite for a backend doing either.
#
# So the pair stays and dd does not. Both jobs are `seq_write_1m` with one flag
# changed, which is what makes them comparable to it and to each other:
#
#   --zero_buffers     every block is zeros. Maximally compressible, and every
#                      block identical, so maximally dedupable.
#   --refill_buffers   fresh random data for every block. fio's default fills
#                      one buffer at startup and rewrites it, which is
#                      incompressible but perfectly dedupable — a distinction
#                      dd could not draw at all and the reason this is not
#                      simply `seq_write_1m` again.
#
# The bonus is that these now carry the time series, the IOPS and the latency
# columns every other test has. dd reported one throughput figure, parsed back
# out of its own English, and no graph.
def fio-job-args [cfg: record]: nothing -> record {
  let size = $"--size=($cfg.fio_size)"
  let engine = $"--ioengine=($cfg.ioengine)"
  let runtime = $"--runtime=($cfg.fio_runtime)"

  {
    seq_write_1m: [
      "--name=seq_write_1m" "--filename=fio_seq.dat" "--rw=write" "--bs=1M"
      $size "--numjobs=1" "--iodepth=16" "--direct=1" $engine $runtime "--time_based"
    ]
    seq_write_zero_1m: [
      "--name=seq_write_zero_1m" "--filename=fio_seq_zero.dat" "--rw=write" "--bs=1M"
      $size "--numjobs=1" "--iodepth=16" "--direct=1" $engine $runtime "--time_based"
      "--zero_buffers"
    ]
    seq_write_rand_1m: [
      "--name=seq_write_rand_1m" "--filename=fio_seq_rand.dat" "--rw=write" "--bs=1M"
      $size "--numjobs=1" "--iodepth=16" "--direct=1" $engine $runtime "--time_based"
      "--refill_buffers"
    ]
    seq_read_1m: [
      "--name=seq_read_1m" "--filename=fio_seq.dat" "--rw=read" "--bs=1M"
      $size "--numjobs=1" "--iodepth=16" "--direct=1" $engine $runtime "--time_based"
    ]
    rand_write_4k: [
      "--name=rand_write_4k" "--filename=fio_rand.dat" "--rw=randwrite" "--bs=4k"
      $size "--numjobs=4" "--iodepth=32" "--direct=1" $engine $runtime "--time_based"
    ]
    rand_read_4k: [
      "--name=rand_read_4k" "--filename=fio_rand.dat" "--rw=randread" "--bs=4k"
      $size "--numjobs=4" "--iodepth=32" "--direct=1" $engine $runtime "--time_based"
    ]
    rand_rw_70_30_4k: [
      "--name=rand_rw_70_30_4k" "--filename=fio_mix.dat" "--rw=randrw" "--rwmixread=70"
      "--bs=4k" $size "--numjobs=4" "--iodepth=32" "--direct=1" $engine $runtime "--time_based"
    ]
    # QD1 with an fsync per write — mimics a database WAL. The most
    # storage-sensitive number here, and the best predictor of real database
    # commit latency. Deliberately its own 1G file and the blocking psync
    # engine rather than the shared FIO_SIZE and IOENGINE.
    fsync_8k_qd1: [
      "--name=fsync_8k_qd1" "--filename=fio_sync.dat" "--rw=randwrite" "--bs=8k"
      "--size=1G" "--numjobs=1" "--iodepth=1" "--fsync=1" "--direct=1"
      "--ioengine=psync" $runtime "--time_based"
    ]
  }
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# PostgreSQL resolves the uid it is running as through getpwuid() and treats a
# failed lookup as fatal — initdb stops at "could not look up effective user
# ID". In a container that is the normal case, not the exception: the image
# knows root and nobody, and the benchmark is deliberately run under the
# caller's uid so the reports are not left root-owned. The image therefore
# ships /etc/passwd as a writable file rather than the usual read-only symlink
# into the store, and this adds the missing line. On a host the entry is
# already there and nothing is written.
def has-passwd-entry [uid: int]: nothing -> bool {
  if not ("/etc/passwd" | path exists) { return false }
  open /etc/passwd
  | lines
  | any {|l| ($l | split row ':' | get --optional 2) == ($uid | into string) }
}

def ensure-passwd-entry [uid: int, gid: int]: nothing -> bool {
  if (has-passwd-entry $uid) { return true }
  let home = (env-str "HOME" "/tmp")
  let line = $"storagebench:x:($uid):($gid):storage-bench:($home):/bin/sh\n"
  # No `test -w`: the write either works or it does not, and trying is the only
  # answer that is not a guess about ACLs and mount options.
  try { $line | save --raw --append /etc/passwd } catch { return false }
  has-passwd-entry $uid
}

# Graphs and rendering are optional extras: a missing tool degrades the report
# rather than failing the benchmark, which by then has already been paid for.
# `missing` collects what was degraded so it can be repeated at the end — a
# benchmark runs for long enough that a warning printed up here has scrolled
# well out of sight by the time anyone looks at the results.
def preflight [cfg: record]: nothing -> record {
  if not (has-cmd "fio") {
    error make --unspanned { msg: "fio not found in PATH" }
  }

  let uid = (uid)
  let gid = (gid)

  mut missing = []

  mut gnuplot = false
  if $cfg.plot {
    if (has-cmd "gnuplot") {
      $gnuplot = true
    } else {
      print --stderr "NOTE gnuplot not found in PATH — the report will have NO GRAPHS"
      $missing = ($missing | append "gnuplot — the report has no graphs")
    }
  }

  mut render = $cfg.render
  if $render != "none" and not (has-cmd "cmark-gfm") {
    print --stderr "NOTE cmark-gfm not found in PATH — report stays as Markdown source"
    $missing = ($missing | append "cmark-gfm — the report was not rendered")
    $render = "none"
  }

  # Read whether or not the workload ends up running: the report header states
  # what postgres is in the image, which is a different question from whether it
  # was used, and `PGBENCH=0` should not blank out the answer.
  let pg_version = (if (has-cmd "postgres") {
    ^postgres --version | complete | get stdout | str trim | split row ' ' | last
  } else { "not present" })

  mut pgbench = false
  mut sockdir = ""
  if $cfg.pgbench {
    if $uid == 0 {
      print --stderr "NOTE running as uid 0 — postgres refuses to run as root, skipping pgbench"
      $missing = ($missing | append "pgbench — skipped, postgres will not run as root")
    } else if not ((has-cmd "initdb") and (has-cmd "pg_ctl") and (has-cmd "pgbench")) {
      print --stderr "NOTE postgres not found in PATH — the report will have NO PGBENCH RESULTS"
      $missing = ($missing | append "postgresql — the pgbench workload did not run")
    } else if not (ensure-passwd-entry $uid $gid) {
      print --stderr $"NOTE uid ($uid) has no /etc/passwd entry and it is not writable —"
      print --stderr "     postgres cannot start, skipping pgbench"
      $missing = ($missing | append $"passwd entry for uid ($uid) — the pgbench workload did not run")
    } else {
      $pgbench = true
    }
  }

  # The socket lives off the mount under test, in TMPDIR, for two reasons: a
  # unix socket on the storage being hammered is not something to measure, and
  # the path has to fit in sockaddr_un.sun_path, which is 108 bytes including
  # the ".s.PGSQL.5432" the server appends. A deep OUTDIR would blow that;
  # TMPDIR usually will not, and if it does the workload is skipped rather than
  # failing halfway through the run.
  if $pgbench {
    let tmp = (env-str "TMPDIR" "/tmp")
    # `mktemp` is a builtin, so this is the one of the five that did not even
    # need /proc.
    let d = (try { mktemp --directory | into string } catch { "" })
    if ($d | is-empty) or ($d | str length) > 90 {
      print --stderr $"NOTE cannot make a short enough socket directory under ($tmp) —"
      print --stderr "     skipping pgbench (unix socket paths are limited to 108 bytes)"
      $missing = ($missing | append $"pgbench — no usable socket directory under ($tmp)")
      if ($d | is-not-empty) { rm --recursive --force $d }
      $pgbench = false
    } else {
      $sockdir = $d
    }
  }

  {
    uid: $uid
    gid: $gid
    gnuplot: $gnuplot
    render: $render
    pgbench: $pgbench
    pg_version: $pg_version
    sockdir: $sockdir
    missing: $missing
  }
}

def usable-mounts [mounts: list<string>, uid: int]: nothing -> list<string> {
  mut out = []
  for mp in $mounts {
    if ($mp | path type) != "dir" {
      print --stderr $"SKIP ($mp) — not a directory"
      continue
    }
    # `touch` and a `test -w` would both be a guess about ACLs and mount
    # options; writing the file is the only answer that is not.
    let probe = $"($mp)/.writetest.nu"
    let ok = (try { "" | save --raw --force $probe; true } catch { false })
    if not $ok {
      print --stderr $"SKIP ($mp) — not writable by uid ($uid)"
      continue
    }
    rm --force $probe
    $out = ($out | append $mp)
  }
  $out
}

# ---------------------------------------------------------------------------
# fio
#
# Uses terse v3 output: semicolon-separated with fixed field positions.
#   $7  read bw KiB/s   $8  read IOPS    $16 read clat mean (us)
#   $48 write bw KiB/s  $49 write IOPS   $57 write clat mean (us)
# awk counts fields from 1, Nushell indexes from 0, hence the off-by-one
# against the comment above. Full terse lines are archived under raw/ if you
# want percentiles later.
#
# --write_{bw,iops,lat}_log additionally dump the run as a time series, one
# sample per LOG_AVG_MSEC window, which is what the graphs are built from.
# per_job_logs=0 puts every job's samples in one file rather than one file per
# job; note that it concatenates them, it does not merge them, so multi-job
# samples still have to be summed per timestamp when plotting.
# ---------------------------------------------------------------------------
def run-fio [
  ctx: record, paths: record, mp: string, name: string, args: list<string>
]: nothing -> record {
  let sl = (slug $mp)
  let raw = $"($paths.rawdir)/fio_($sl)_($name).terse"
  let logbase = $"($paths.logdir)/($sl)_($name)"

  let failed = {
    kind: fio
    row: {
      run: $paths.run_id, mount: $mp, test: $name
      read_iops: FAILED, read_bw_kibs: FAILED, read_clat_mean_us: FAILED
      write_iops: FAILED, write_bw_kibs: FAILED, write_clat_mean_us: FAILED
    }
  }

  info $"fio ($name) ..."
  let res = (
    ^fio --output-format=terse --terse-version=3
      $"--directory=($mp)" --group_reporting
      $"--write_bw_log=($logbase)"
      $"--write_iops_log=($logbase)"
      $"--write_lat_log=($logbase)"
      $"--log_avg_msec=($ctx.cfg.log_avg_msec)" --per_job_logs=0
      ...$args
    | complete
  )
  let out = (merged $res)
  $out | save --raw --force $raw

  let terse = ($out | lines | where {|l| $l =~ '^[0-9]+;' })

  if $res.exit_code != 0 or ($terse | is-empty) {
    info $"  FAILED \(see ($raw))"
    return $failed
  }

  let f = ($terse | last | split row ';')
  let row = {
    run: $paths.run_id, mount: $mp, test: $name
    read_iops: ($f | get 7), read_bw_kibs: ($f | get 6), read_clat_mean_us: ($f | get 15)
    write_iops: ($f | get 48), write_bw_kibs: ($f | get 47), write_clat_mean_us: ($f | get 56)
  }
  info $"  read: ($row.read_iops) IOPS / write: ($row.write_iops) IOPS"
  { kind: fio, row: $row }
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
def pg-conf-args [ctx: record]: nothing -> string {
  [
    "-c listen_addresses=''"
    $"-c unix_socket_directories=($ctx.caps.sockdir)"
    "-c fsync=on"
    "-c synchronous_commit=on"
    "-c full_page_writes=on"
    $"-c max_wal_size=($ctx.cfg.pgbench_max_wal)"
    $"-c max_connections=($ctx.cfg.pgbench_clients + 8)"
  ] | str join " "
}

def pg-stop [pgdata: path] {
  ^pg_ctl -D $pgdata -m immediate -w stop | complete | ignore
}

def run-pgbench [ctx: record, paths: record, mp: string]: nothing -> record {
  let cfg = $ctx.cfg
  let sl = (slug $mp)
  let pgdata = $"($mp)/pgdata"
  let prefix = $"($paths.logdir)/pgbench_($sl)"
  let raw = $"($paths.rawdir)/pgbench_($sl).txt"
  let serverlog = $"($paths.rawdir)/pgbench_($sl)_server.log"

  let failrow = {
    kind: pgbench
    row: {
      run: $paths.run_id, mount: $mp, scale: $cfg.pgbench_scale
      clients: $cfg.pgbench_clients, threads: $cfg.pgbench_jobs
      mode: $cfg.pgbench_mode, warmup_s: $cfg.pgbench_warmup
      duration_s: $cfg.pgbench_time
      init_s: FAILED, tps: FAILED, latency_avg_ms: FAILED
      transactions: FAILED, failed: FAILED
    }
  }

  # A cluster left behind by an earlier run would mean measuring a load that
  # never happened, so each run starts from initdb.
  rm --recursive --force $pgdata

  info "pgbench initdb ..."
  let init = (^initdb -D $pgdata -U postgres --locale=C --encoding=UTF8 -A trust | complete)
  (merged $init) | save --raw --force $raw
  if $init.exit_code != 0 {
    info $"  initdb FAILED \(see ($raw))"
    return $failrow
  }

  info "pgbench starting postgres ..."
  # -w with a generous timeout: the server has to fsync its way through
  # startup on storage that may be slow, which is after all the point.
  let start = (
    ^pg_ctl -D $pgdata -l $serverlog -w -t 120 -o (pg-conf-args $ctx) start | complete
  )
  (merged $start) | save --raw --append $raw
  if $start.exit_code != 0 {
    info $"  postgres FAILED to start \(see ($serverlog))"
    return $failrow
  }

  let created = (^createdb -h $ctx.caps.sockdir -U postgres bench | complete)
  (merged $created) | save --raw --append $raw
  if $created.exit_code != 0 {
    info $"  createdb FAILED \(see ($raw))"
    pg-stop $pgdata
    return $failrow
  }

  # ---- load --------------------------------------------------------------
  # Bulk write throughput through the database rather than through dd: table
  # heap, index build and the vacuum that follows. pgbench times itself, and
  # its own figure is used rather than a wall clock around it so the number
  # means the same thing as the one pgbench prints.
  info $"pgbench load \(scale ($cfg.pgbench_scale)) ..."
  let load = (
    ^pgbench -i -s $cfg.pgbench_scale -h $ctx.caps.sockdir -U postgres bench | complete
  )
  let loadout = (merged $load)
  $loadout | save --raw --append $raw
  if $load.exit_code != 0 {
    info $"  load FAILED \(see ($raw))"
    pg-stop $pgdata
    return $failrow
  }
  let init_s = (last-capture $loadout '^done in ([0-9.]+) s ' | default "n/a")
  info $"  loaded in ($init_s)s"

  # ---- warmup ------------------------------------------------------------
  # Unlogged and unmeasured, purely to get the cluster out of its cold start:
  # the buffer cache filled, the WAL past its first recycle, and at least one
  # checkpoint behind it. Its output is kept in raw/ so the discarded numbers
  # can still be compared against the measured ones.
  if $cfg.pgbench_warmup > 0 {
    info $"pgbench warmup \(($cfg.pgbench_warmup)s, not measured) ..."
    "\n=== warmup, not measured ===\n" | save --raw --append $raw
    let warm = (
      ^pgbench -h $ctx.caps.sockdir -U postgres
        -c $cfg.pgbench_clients -j $cfg.pgbench_jobs -T $cfg.pgbench_warmup
        -M $cfg.pgbench_mode bench
      | complete
    )
    let warmout = (merged $warm)
    $warmout | save --raw --append $raw
    info $"  warmed at (last-capture $warmout '^tps = ([0-9.]+)' | default 'n/a') tps"
  }

  # ---- timed run ---------------------------------------------------------
  # --log with --aggregate-interval gives one row per interval per thread,
  # which pgbench-series folds back together for the graphs. Without the
  # aggregate it would log every single transaction — millions of lines.
  #
  # --no-vacuum because the warmup has just left the tables in the state a
  # running database is in, and pgbench's default pre-run vacuum would undo
  # exactly that. With no warmup the cluster was freshly loaded and pgbench
  # vacuums as part of the load, so there is nothing for it to do either way.
  #
  # -P prints a progress line to the raw output; on a run measured in minutes
  # it is the only sign it is still alive.
  info $"pgbench run \(($cfg.pgbench_clients) clients, ($cfg.pgbench_mode), ($cfg.pgbench_time)s) ..."
  "\n=== measured run ===\n" | save --raw --append $raw
  glob $"($prefix).*" | each {|f| rm --force $f } | ignore
  let run = (
    ^pgbench -h $ctx.caps.sockdir -U postgres
      -c $cfg.pgbench_clients -j $cfg.pgbench_jobs -T $cfg.pgbench_time
      -M $cfg.pgbench_mode --no-vacuum -P 10
      --log $"--log-prefix=($prefix)"
      $"--aggregate-interval=($PGBENCH_AGG_INTERVAL)" bench
    | complete
  )
  let runout = (merged $run)
  $runout | save --raw --append $raw

  pg-stop $pgdata

  if $run.exit_code != 0 {
    info $"  run FAILED \(see ($raw))"
    rm --recursive --force $pgdata
    return $failrow
  }

  let tps = (last-capture $runout '^tps = ([0-9.]+)' | default "n/a")
  let lat = (last-capture $runout '^latency average = ([0-9.]+) ms' | default "n/a")
  let txns = (last-capture $runout '^number of transactions actually processed: ([0-9]+)' | default "n/a")
  let failed = (last-capture $runout '^number of failed transactions: ([0-9]+)' | default "0")

  info $"  ($tps) tps, ($lat)ms mean latency"

  # The cluster is ~16 MiB per scale point and the next mount wants the space.
  rm --recursive --force $pgdata

  {
    kind: pgbench
    row: {
      run: $paths.run_id, mount: $mp, scale: $cfg.pgbench_scale
      clients: $cfg.pgbench_clients, threads: $cfg.pgbench_jobs
      mode: $cfg.pgbench_mode, warmup_s: $cfg.pgbench_warmup
      duration_s: $cfg.pgbench_time
      init_s: $init_s, tps: $tps, latency_avg_ms: $lat
      transactions: $txns, failed: $failed
    }
  }
}

# ---------------------------------------------------------------------------
# One test against one mount
#
# The shell version's `case` had one arm per test, six of which were a `run_fio`
# call differing only in flags. With the dd arms gone that whole shape goes with
# them: every test but pgbench is an fio job, and its flags are already a lookup
# away in ctx.
# ---------------------------------------------------------------------------
def run-test [ctx: record, paths: record, mp: string, test: string]: nothing -> any {
  # Skipped rather than failed when postgres is unavailable — the preflight has
  # already said why, and the rest of the suite is still worth finishing.
  if $test == "pgbench" {
    return (if $ctx.caps.pgbench { run-pgbench $ctx $paths $mp } else { null })
  }

  let args = ($ctx.fio_args | get --optional $test)
  if $args == null {
    print --stderr $"unknown test: ($test)"
    return null
  }
  run-fio $ctx $paths $mp $test $args
}

# ---------------------------------------------------------------------------
# Series reduction
#
# This is where the two versions diverge most. The shell version reduces fio's
# logs with awk — associative arrays keyed by bucket, a manual sum/count pair
# for the average, and a `| sort -n` afterwards because awk's `for (b in sum)`
# has no order. Here it is a group-by and `math sum` / `math avg` over records,
# and the result stays a table until something asks for text.
# ---------------------------------------------------------------------------

# Reduce one fio log to time/value pairs for a single data direction.
# Concurrent jobs each emit their own sample per window (per_job_logs=0 only
# concatenates them), so throughput has to be summed across jobs while latency
# is averaged. Timestamps drift by a millisecond or two between jobs, hence the
# rounding onto the nearest window boundary before grouping.
#
# Every fio log line is:   time_ms, value, ddir, blocksize, offset
# with ddir 0 = read, 1 = write, 2 = trim.
def fio-series [
  file: path, ddir: int, mode: string, scale: float, drop: bool, win: int
]: nothing -> table {
  if not (file-has-content $file) { return [] }

  open --raw $file
  | lines
  | where {|l| ($l | str trim) != "" }
  | each {|l|
      let c = ($l | split row --regex '[\s,]+')
      { t: ($c.0 | into float), v: ($c.1 | into float), d: ($c.2 | into int) }
    }
  | where d == $ddir
  | where {|r| (not $drop) or ($r.v > 0) }
  | insert bucket {|r| ((($r.t + $win / 2) / $win) | math floor) * $win }
  | group-by {|r| $r.bucket | into string }
  | items {|bucket, rows|
      {
        time: (($rows.0.bucket | into float) / 1000)
        value: ((if $mode == "avg" { $rows.v | math avg } else { $rows.v | math sum }) * $scale)
      }
    }
  | sort-by time
}

# Reduce pgbench's aggregate logs to time/value pairs. Every worker thread
# writes its own file — <prefix>.<pid> for the first and <prefix>.<pid>.<n> for
# the rest — so the rows for one interval have to be combined across them:
# transactions summed, mean latency weighted by transaction count, worst-case
# latency taken as the worst any thread saw.
#
# Latencies in the log are microseconds. Interval timestamps are absolute Unix
# seconds, so they are rebased onto the start of the run to match the fio
# graphs, whose x axis is also elapsed-within-the-run.
#
# Columns are: interval_start num_transactions sum_latency sum_latency_2
#              min_latency max_latency
def pgbench-series [prefix: string, mode: string]: nothing -> table {
  let files = (glob $"($prefix).*" | where {|f| file-has-content $f })
  if ($files | is-empty) { return [] }

  let rows = (
    $files
    | each {|f| open --raw $f | lines }
    | flatten
    | where {|l| ($l | str trim) != "" }
    | each {|l|
        let c = ($l | split row --regex '\s+')
        { t: ($c.0 | into int), tx: ($c.1 | into int), lat: ($c.2 | into float), mx: ($c.5 | into float) }
      }
  )
  if ($rows | is-empty) { return [] }

  let lo = ($rows.t | math min)
  let hi = ($rows.t | math max)
  let folded = (
    $rows
    | group-by {|r| $r.t | into string }
    | items {|interval, g|
        { t: $g.0.t, tx: ($g.tx | math sum), lat: ($g.lat | math sum), mx: ($g.mx | math max) }
      }
  )

  # The first and last intervals are partial — the run started and stopped
  # partway through a second — so both read as a dip that is an artefact of the
  # clock rather than the storage. Dropped, unless the run was so short that
  # dropping them would leave nothing.
  let trim = ($folded | length) >= 3

  $folded
  | where {|r| not ($trim and ($r.t == $lo or $r.t == $hi)) }
  | where tx > 0
  | each {|r|
      {
        time: (($r.t - $lo) | into float)
        value: (match $mode {
          "tps" => ($r.tx / $PGBENCH_AGG_INTERVAL)
          "lat" => ($r.lat / $r.tx / 1000)
          _ => ($r.mx / 1000)
        })
      }
    }
  | sort-by time
}

# Fold the same series from every pass into one time/mean/min/max table. The
# passes share a time base — each series is already rebased onto the start of
# its own run — so the buckets line up and can simply be averaged across files.
#
# A bucket at the very end may exist in only some passes, if one run produced a
# sample a fraction of a window later than the others. Averaging over however
# many passes actually reached that bucket is the honest answer; the band there
# collapses onto the line, which is the correct picture of a single sample.
def aggregate-series [files: list<string>]: nothing -> table {
  $files
  | each {|f| open --raw $f | lines | where {|l| ($l | str trim) != "" } | each {|l|
      let c = ($l | split row --regex '\s+')
      { time: ($c.0 | into float), value: ($c.1 | into float) }
    }}
  | flatten
  | group-by {|r| $r.time | into string }
  | items {|bucket, g|
      {
        time: $g.0.time
        value: ($g.value | math avg)
        min: ($g.value | math min)
        max: ($g.value | math max)
      }
    }
  | sort-by time
}

# gnuplot reads columns of text, so a series has to leave the type system here.
# Kept to one function so it is the only place that does.
def save-series [series: table, dat: path]: nothing -> bool {
  if ($series | is-empty) { return false }
  let has_band = ("min" in ($series | columns))
  let text = (
    $series
    | each {|r|
        let t = ($r.time | into string --decimals 3)
        let v = ($r.value | into string --decimals 6)
        if $has_band {
          let lo = ($r.min | into string --decimals 6)
          let hi = ($r.max | into string --decimals 6)
          $"($t) ($v) ($lo) ($hi)"
        } else {
          $"($t) ($v)"
        }
      }
    | str join "\n"
  )
  $"($text)\n" | save --raw --force $dat
  true
}

# ---------------------------------------------------------------------------
# Graphs
#
# One graph per fio test per metric, with every mount (and both directions,
# where the job does both) drawn on the same axes so a head-to-head comparison
# is one glance rather than two files.
#
# The x axis is time *within* that job, not wall clock: each fio run restarts at
# zero, which is what makes runs on different mounts comparable even in by-mount
# order where they are minutes apart.
# ---------------------------------------------------------------------------

# The gnuplot elements for one series. In the shell version this had to hand its
# result back through a global, because the strings are full of spaces and
# quotes and would not survive command substitution; here it just returns a
# list.
#
# A per-pass chart is one line. An aggregate is the min-max band across passes,
# shaded, with the mean drawn over it — both in the same colour, so the pair
# reads as one series rather than two. A wide band means the storage did not do
# the same thing twice, which is the reason for running it more than once.
def plot-parts [
  dat: path, title: string, style: string, ci: int, di: int = 0
]: nothing -> list<string> {
  let color = ($PLOT_COLORS | get ($ci mod ($PLOT_COLORS | length)))
  match $style {
    "band" => [
      $"'($dat)' using 1:3:4 with filledcurves fc rgb '($color)' fs transparent solid 0.18 notitle"
      $"'($dat)' using 1:2 with lines lw 2 lc rgb '($color)' title '($title)'"
    ]
    # One colour per series, one dash pattern per pass, so the same series in
    # different passes stays visibly the same series. Colouring by pass instead
    # would run out of distinguishable colours as soon as there is more than one
    # mount, and would make two unrelated lines look related.
    # gnuplot's dashtypes: 1 solid, 2 dashed, 3 dotted, 4 dash-dot, 5 dash-dot-dot.
    "dash" => [
      $"'($dat)' using 1:2 with lines lw 2 lc rgb '($color)' dt (($di mod 5) + 1) title '($title)'"
    ]
    _ => [
      $"'($dat)' using 1:2 with lines lw 2 title '($title)'"
    ]
  }
}

# The gnuplot half of a chart, shared by the fio and pgbench plots so there is
# one place where the terminal, the axes and the legend are decided. Each part
# is a complete gnuplot `plot` element. Returns false if given nothing.
def render-plot [
  ctx: record, img: path, gp: path, desc: string, xlabel: string, ylabel: string,
  logscale: bool, parts: list<string>
]: nothing -> bool {
  if ($parts | is-empty) { return false }

  # One element per line, joined with gnuplot's backslash continuation, rather
  # than one long line. gnuplot stops parsing a command line somewhere past 2 KB
  # — a plot of six series whose titles and data paths both carry a deep mount
  # path reaches that — and the failure is a syntax error pointing at the
  # truncation, having already written a partial SVG, so it does not even look
  # like a length problem. It also makes the .gp files readable, which matters
  # because the report invites people to re-run them.
  let plotline = ($parts | str join ", \\\n     ")

  # The legend sits below the plot, one entry per row, and the canvas grows to
  # make room for the rows. It used to sit outside right, which gnuplot sizes by
  # reserving space for the widest label — and the labels are mount paths. A
  # short one costs nothing, but a PVC mounted somewhere deep took the plot from
  # 917px of the 1100px canvas down to 245px, which is a tenth of the resolution
  # for the same number of samples. Below the plot, the label length stops
  # mattering.
  #
  # Only the parts that will appear in the legend earn a row. The aggregate
  # plots draw a spread band behind each mean line, and those bands are
  # `notitle` — counting them would leave a strip of empty canvas under every
  # aggregate chart.
  let legend = ($parts | where {|p| not ($p | str contains "notitle") } | length)
  let height = 420 + 24 * $legend

  # Everything emitted below is deliberately ASCII: gnuplot's iconv cannot
  # convert its own non-ASCII glyphs under a C locale and warns once per plot.
  #
  # svg rather than pngcairo: the SVG terminal is built into gnuplot and needs
  # no libraries at all, where pngcairo wants cairo, pango, glib, harfbuzz,
  # freetype, fontconfig and a font — ~55 MB of image to rasterise a line chart
  # the browser can draw itself. It also scales, which a 1100px PNG did not.
  #
  # The font is named generically because the image no longer carries one.
  # noenhanced: test names and mount paths are full of underscores, which
  # gnuplot's enhanced text would render as subscripts. An explicit white
  # background, because the SVG terminal otherwise leaves it transparent and the
  # black axis text then disappears against a dark-mode page.
  let yaxis = (if $logscale { ["set logscale y" "set format y '%.0s%c'"] } else { ["set yrange [0:*]"] })

  [
    $"set terminal svg noenhanced size 1100,($height) font 'sans-serif,10' background rgb 'white'"
    $"set output '($img)'"
    $"set title '($desc)'"
    $"set xlabel '($xlabel)'"
    $"set ylabel '($ylabel)'"
    "set grid xtics ytics lc rgb '#c8c8c8'"
    "set key below maxcols 1"
    "set xrange [0:*]"
    ...$yaxis
    $"plot ($plotline)"
  ]
  | str join "\n"
  | save --raw --force $gp

  let res = (^gnuplot $gp | complete)
  if ($res.stderr | is-not-empty) {
    $res.stderr | save --raw --append $"($ctx.plotdir)/gnuplot.log"
  }
  ($res.exit_code == 0) and (file-has-content $img)
}

# One SVG for one (test, metric), overlaying every mount and direction that
# produced samples. Returns false if there was nothing to draw.
#
# With `agg` as the pass id it plots the mean across passes with the min-max
# spread shaded behind it, reading the per-pass .dat files that the earlier
# calls left behind; otherwise it plots that one pass.
def plot-metric [
  ctx: record, rid: string, test: string, suffix: string, key: string,
  mode: string, scale: float, ylabel: string, desc: string, logscale: bool
]: nothing -> bool {
  let style = (if $rid == "agg" { "band" } else { "line" })

  # Derived from the pass being drawn, not from whichever pass ran last: the
  # graphs are drawn after every pass has finished, so reading a "current pass"
  # variable here would plot every pass from the last one's logs and average the
  # last pass with itself.
  let outdir = (if $rid == "agg" { $"($ctx.plotdir)/aggregate" } else { $"($ctx.plotdir)/($rid)" })
  let logdir = $"($ctx.outdir)/fio-logs/($rid)"
  let datdir = $"($ctx.plotdir)/data/($rid)"
  mkdir $outdir $datdir

  mut parts = []
  mut ci = 0

  for mp in $ctx.usable {
    let sl = (slug $mp)
    for d in [0 1] {
      let dname = ($DDIR_NAME | get $d)
      let title = (if ($ctx.usable | length) > 1 { $"($mp) ($dname)" } else { $dname })

      let dat = (if $rid == "agg" {
        $"($ctx.plotdir)/data/aggregate_($sl)_($test)_($key)_($dname).dat"
      } else {
        $"($datdir)/($sl)_($test)_($key)_($dname).dat"
      })

      let drew = (if $rid == "agg" {
        let srcs = (
          $ctx.run_ids
          | each {|r| $"($ctx.plotdir)/data/($r)/($sl)_($test)_($key)_($dname).dat" }
          | where {|f| file-has-content $f }
        )
        if ($srcs | is-empty) { false } else { save-series (aggregate-series $srcs) $dat }
      } else {
        # logscale doubles as the drop-non-positive flag: a zero is a real datum
        # on a throughput plot (the backend stalled) and must stay, but it has no
        # place on a log axis, where gnuplot would silently drop it anyway.
        let series = (fio-series $"($logdir)/($sl)_($test)($suffix)" $d $mode $scale $logscale $ctx.cfg.log_avg_msec)
        save-series $series $dat
      })

      if $drew {
        $parts = ($parts | append (plot-parts $dat $title $style $ci))
        $ci = $ci + 1
      } else {
        rm --force $dat
      }
    }
  }

  render-plot $ctx $"($outdir)/($test)_($key).svg" $"($outdir)/($test)_($key).gp" $"($desc) - ($test)" "elapsed within the fio run (s)" $ylabel $logscale $parts
}

# The pgbench counterpart: one metric, every mount on the same axes. There is
# no read/write split here — a TPC-B transaction is both.
def plot-pgbench [
  ctx: record, rid: string, key: string, mode: string,
  ylabel: string, desc: string, logscale: bool
]: nothing -> bool {
  let style = (if $rid == "agg" { "band" } else { "line" })
  let outdir = (if $rid == "agg" { $"($ctx.plotdir)/aggregate" } else { $"($ctx.plotdir)/($rid)" })
  let logdir = $"($ctx.outdir)/fio-logs/($rid)"
  let datdir = $"($ctx.plotdir)/data/($rid)"
  mkdir $outdir $datdir

  mut parts = []
  mut ci = 0

  for mp in $ctx.usable {
    let sl = (slug $mp)
    let title = (if ($ctx.usable | length) > 1 { $mp } else { "pgbench" })

    let dat = (if $rid == "agg" {
      $"($ctx.plotdir)/data/aggregate_($sl)_pgbench_($key).dat"
    } else {
      $"($datdir)/($sl)_pgbench_($key).dat"
    })

    let drew = (if $rid == "agg" {
      let srcs = (
        $ctx.run_ids
        | each {|r| $"($ctx.plotdir)/data/($r)/($sl)_pgbench_($key).dat" }
        | where {|f| file-has-content $f }
      )
      if ($srcs | is-empty) { false } else { save-series (aggregate-series $srcs) $dat }
    } else {
      save-series (pgbench-series $"($logdir)/pgbench_($sl)" $mode) $dat
    })

    if $drew {
      $parts = ($parts | append (plot-parts $dat $title $style $ci))
      $ci = $ci + 1
    } else {
      rm --force $dat
    }
  }

  render-plot $ctx $"($outdir)/pgbench_($key).svg" $"($outdir)/pgbench_($key).gp" $"($desc) - pgbench" "elapsed within the pgbench run (s)" $ylabel $logscale $parts
}

# Every pass on one set of axes, unaggregated. The aggregate answers "what does
# this storage do"; this answers "did it do the same thing every time", and
# unlike the band it names the pass that disagreed — a first pass that was slow
# because a cache was cold looks nothing like one pass in three stalling at
# random, and the band renders both as the same width.
#
# Reads the per-pass .dat files the pass loop already wrote, so it has to run
# after them.
def plot-compare [
  ctx: record, base: string, key: string, ylabel: string, desc: string, logscale: bool
]: nothing -> bool {
  let outdir = $"($ctx.plotdir)/compare"
  mkdir $outdir

  let is_pg = ($base == "pgbench")
  let dirs = (if $is_pg { [-1] } else { [0 1] })
  let xlabel = (if $is_pg { "elapsed within the pgbench run (s)" } else { "elapsed within the fio run (s)" })

  mut parts = []
  mut ci = 0

  for mp in $ctx.usable {
    let sl = (slug $mp)
    for d in $dirs {
      mut di = 0
      mut drew = false
      for r in $ctx.run_ids {
        let dat = (if $is_pg {
          $"($ctx.plotdir)/data/($r)/($sl)_pgbench_($key).dat"
        } else {
          $"($ctx.plotdir)/data/($r)/($sl)_($base)_($key)_($DDIR_NAME | get $d).dat"
        })
        let base_title = (if $is_pg { $r } else { $"($r) ($DDIR_NAME | get $d)" })
        let title = (if ($ctx.usable | length) > 1 { $"($base_title) ($mp)" } else { $base_title })

        if (file-has-content $dat) {
          $parts = ($parts | append (plot-parts $dat $title "dash" $ci $di))
          $drew = true
        }
        # The dash index still advances for a pass that produced nothing, so a
        # pass keeps the same dash pattern in every chart it appears in.
        $di = $di + 1
      }
      # Only a series that drew something consumes a colour, so the colours stay
      # dense rather than leaving gaps for write-only tests.
      if $drew { $ci = $ci + 1 }
    }
  }

  render-plot $ctx $"($outdir)/($base)_($key).svg" $"($outdir)/($base)_($key).gp" $"($desc) - ($base), every pass" $xlabel $ylabel $logscale $parts
}

def draw-graphs [ctx: record]: nothing -> record {
  if not $ctx.caps.gnuplot {
    return { pgbench: false, compare: false, aggregate: false }
  }

  log-section "Drawing graphs"

  # Per pass first, then the aggregate, which reads the per-pass data files the
  # first loop wrote. With REPEATS=1 the aggregate would be the same chart drawn
  # a second time, so it is skipped.
  let multi = $ctx.cfg.repeats > 1
  let passes = (if $multi { $ctx.run_ids | append "agg" } else { $ctx.run_ids })

  mut pgbench_graphed = false
  mut agg_graphed = false
  mut cmp_graphed = false

  for rid in $passes {
    if $multi { info (if $rid == "agg" { "aggregate:" } else { $"($rid):" }) }

    for t in $ctx.fio_tests {
      # bandwidth is logged in KiB/s; 1/1024 puts it in MiB/s.
      # clat is logged in nanoseconds; 1/1000 puts it in microseconds.
      let drawn = ([
        (plot-metric $ctx $rid $t "_iops.log" "iops" "sum" 1.0 "IOPS" "IOPS over time" false)
        (plot-metric $ctx $rid $t "_bw.log" "bw" "sum" 0.0009765625 "bandwidth (MiB/s)" "Bandwidth over time" false)
        (plot-metric $ctx $rid $t "_clat.log" "clat" "avg" 0.001 "completion latency (us)" "Completion latency over time" true)
      ] | any {|x| $x })
      info (if $drawn { $"  ($t)" } else { $"  ($t) — no samples, skipped" })
      if $rid == "agg" and $drawn { $agg_graphed = true }
    }

    if $ctx.caps.pgbench {
      let drawn = ([
        (plot-pgbench $ctx $rid "tps" "tps" "transactions/s" "Transaction rate over time" false)
        (plot-pgbench $ctx $rid "lat" "lat" "mean latency (ms)" "Mean transaction latency over time" true)
        # Worst case rather than mean, because the mean hides exactly what
        # storage does to a database: a checkpoint or an fsync stall shows up as
        # one interval where the slowest transaction took a hundred times the
        # average.
        (plot-pgbench $ctx $rid "maxlat" "maxlat" "worst latency (ms)" "Worst transaction latency over time" true)
      ] | any {|x| $x })
      if $drawn { $pgbench_graphed = true }
      if $rid == "agg" and $drawn { $agg_graphed = true }
      info (if $drawn { "  pgbench" } else { "  pgbench — no samples, skipped" })
    }
  }

  # Last, because it reads what every pass above wrote.
  if $multi {
    info "every pass on one axis:"
    for t in $ctx.fio_tests {
      let drawn = ([
        (plot-compare $ctx $t "iops" "IOPS" "IOPS over time" false)
        (plot-compare $ctx $t "bw" "bandwidth (MiB/s)" "Bandwidth over time" false)
        (plot-compare $ctx $t "clat" "completion latency (us)" "Completion latency over time" true)
      ] | any {|x| $x })
      if $drawn { $cmp_graphed = true }
      info (if $drawn { $"  ($t)" } else { $"  ($t) — no samples, skipped" })
    }

    if $ctx.caps.pgbench {
      let drawn = ([
        (plot-compare $ctx "pgbench" "tps" "transactions/s" "Transaction rate over time" false)
        (plot-compare $ctx "pgbench" "lat" "mean latency (ms)" "Mean transaction latency over time" true)
        (plot-compare $ctx "pgbench" "maxlat" "worst latency (ms)" "Worst transaction latency over time" true)
      ] | any {|x| $x })
      if $drawn { $cmp_graphed = true }
      info (if $drawn { "  pgbench" } else { "  pgbench — no samples, skipped" })
    }
  }

  { pgbench: $pgbench_graphed, compare: $cmp_graphed, aggregate: $agg_graphed }
}

# ---------------------------------------------------------------------------
# Markdown report
#
# GitHub-Flavoured Markdown, which means the report is readable as-is in a
# terminal, a pull request or an issue comment without being rendered at all —
# the reason it is Markdown rather than AsciiDoc.
#
# The cost of that trade is paid here: Markdown has no `include::`, so the
# results have to be turned into tables rather than referenced, and it has no
# section numbering, table of contents, anchors or captions, all of which
# render-html adds afterwards. The CSVs stay in the results directory as the
# machine-readable copy; `to md` produces the human one, which in the shell
# version was a 19-line awk program.
# ---------------------------------------------------------------------------

# What each fio job is for, in the report's words. Kept next to nothing else on
# purpose: the flags themselves are quoted from ctx.fio_args, so this only has
# to explain intent and never has to be kept in step with the command line.
def fio-test-purpose [test: string]: nothing -> string {
  match $test {
    "seq_write_1m" => r#'
Streaming write bandwidth. One worker pushing 1 MiB blocks with 16 requests in
flight — large enough blocks and deep enough queue that the backend has every
chance to coalesce and pipeline, so this is close to the best sequential number
it can produce. This is the figure that predicts bulk restores, backup writes,
image pulls and log shipping.
'#
    "seq_write_zero_1m" => r#'
`seq_write_1m` again, with `--zero_buffers`: every block written is zeros. That
is the most compressible and the most dedupable data there is, so a backend
doing either inline will beat its own `seq_write_1m` figure here, sometimes by
an order of magnitude, without a byte of it reaching a disk. A backend that
stores what it is given produces the same number twice.

This is one half of what `dd if=/dev/zero` was for. It is the optimistic bound:
no real workload writes only zeros, and any storage vendor's headline
throughput figure that looks like this one is quoting it.
'#
    "seq_write_rand_1m" => r#'
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
'#
    "seq_read_1m" => r#'
Streaming read bandwidth, reading back the file `seq_write_1m` just wrote. Same
shape as the write test, so the two are directly comparable; a backend that
reads much faster than it writes is usually acknowledging writes to a slower
durable tier, or replicating them.

O_DIRECT, like everything else here, so this is the storage rather than the
page cache — which is what `dd iflag=direct` was checking, and this one cannot
silently fall back to a cached read the way dd did.
'#
    "rand_write_4k" => r#'
Write IOPS under concurrency. Four workers share one file, each with 32 requests
outstanding, so up to 128 4 KiB writes are in flight at once. Blocks this small
and scattered defeat readahead and write coalescing, which is the point: it
measures how many discrete operations the backend can retire per second rather
than how much data it can stream.
'#
    "rand_read_4k" => r#'
Read IOPS under the same concurrency, against the file `rand_write_4k` left
behind. With the page cache bypassed every one of these has to be served by the
backend, so this is the read-side counterpart to the number above.
'#
    "rand_rw_70_30_4k" => r#'
The same random 4 KiB workload with reads and writes interleaved, 70% read to
30% write, which is far closer to what an application actually does than either
pure test. It is also where backends that look fine in isolation come apart:
read-modify-write on parity layouts, and log-structured stores whose compaction
only kicks in once writes are mixed in, both show up here and not above.
'#
    "fsync_8k_qd1" => r#'
Commit latency, and the number that usually separates one storage class from
another. A single worker, one request outstanding, `fsync` after every 8 KiB
write: no concurrency, so nothing can hide the round trip and every write must
be durable before the next one starts. This is what a database WAL does, and
the IOPS figure here is roughly the transaction rate a synchronous commit can
expect. It deliberately uses the blocking `psync` engine and a fixed 1G file
rather than the shared `FIO_SIZE`, because queue depth 1 is the whole point.
'#
    _ => ""
  }
}

# The three charts for one test, if they were drawn. The alt text doubles as the
# caption: render-html lifts a paragraph that holds nothing but an image into a
# <figure> and reuses it as the <figcaption>, which is as close as Markdown gets
# to AsciiDoc's `.Title`.
def emit-graphs [
  ctx: record, base: string, subject: string, rid: string
]: nothing -> string {
  if ($rid | is-empty) { return "" }
  let suffix = (match $rid {
    "compare" => $" \(all ($ctx.cfg.repeats) passes)"
    $x if $x == $ctx.headline.graphs => $ctx.headline.suffix
    _ => $" \(($rid))"
  })

  let specs = (if $base == "pgbench" {
    [[key cap]; [tps "Transaction rate"] [lat "Mean latency"] [maxlat "Worst latency"]]
  } else {
    [[key cap]; [iops IOPS] [bw Bandwidth] [clat "Completion latency"]]
  })

  $specs
  | each {|s|
      let svg = $"($ctx.plotdir)/($rid)/($base)_($s.key).svg"
      if ($svg | path exists) {
        $"![($s.cap) — ($subject)($suffix)]\(graphs/($rid)/($base)_($s.key).svg)\n"
      } else { null }
    }
  | str join "\n"
}

def report-header [ctx: record, elapsed: int]: nothing -> string {
  let cfg = $ctx.cfg
  let props = [
    [Property Value];
    ["Generated" (date now | date to-timezone UTC | format date '%Y-%m-%d %H:%M:%S UTC')]
    ["Total runtime" $"($elapsed)s"]
    ["Host / pod" (hostname)]
    ["Kernel" (kernel-release)]
    ["Running as" $"uid ($ctx.caps.uid), gid ($ctx.caps.gid)"]
    ["fio version" (^fio --version | complete | get stdout | str trim)]
    ["postgres version" $ctx.caps.pg_version]
    ["Mounts under test" ($ctx.usable | str join " ")]
    ["Run order" $cfg.order]
  ]

  let params = [
    [Parameter Value];
    ["Run order" $cfg.order]
    ["Passes over the suite" ($cfg.repeats | into string)]
    ["Settle between runs" $"($cfg.settle)s"]
    ["Settle between tests" $"($cfg.test_settle)s"]
    ["fio working set" $cfg.fio_size]
    ["fio runtime per job" $"($cfg.fio_runtime)s"]
    ["fio ioengine" $cfg.ioengine]
    ["fio log sample window" $"($cfg.log_avg_msec)ms"]
    ["pgbench" (if $ctx.caps.pgbench {
      $"scale ($cfg.pgbench_scale), ($cfg.pgbench_clients) clients, ($cfg.pgbench_jobs) threads, ($cfg.pgbench_mode), ($cfg.pgbench_warmup)s warmup + ($cfg.pgbench_time)s measured"
    } else { "not run" })]
  ]

  [
    "# Storage Benchmark Report"
    ""
    ($props | to md --pretty)
    ""
    "## Test parameters"
    ""
    ($params | to md --pretty)
    ""
    "## Reading these numbers"
    ""
    $"* Run order was `($cfg.order)`. In `by-mount` each mount gets an uninterrupted block of tests; in `by-test` the mounts are paired closely in time so shared backend load hits both about equally. If the two paths share physical hardware, `by-test` is the fairer head-to-head."
    $"* A ($cfg.settle)s idle period separates consecutive runs, and a shorter ($cfg.test_settle)s one separates consecutive tests within a run, so that one job's writeback does not land inside the next job's first samples."
    "* What each fio job measures, and the exact command it ran, is in [fio tests](#fio-tests) — including the flags all of them share, such as `--direct=1` to keep the page cache out of the results. If you read one section before the numbers, read that one."
    "* `seq_write_1m`, `seq_write_zero_1m` and `seq_write_rand_1m` are the same job with different data in the buffer: whatever fio writes by default, all zeros, and fresh random bytes per block. On a backend that stores what it is given they are one number three times. Where they diverge, the backend is looking at the content — zeros compressing away, or identical blocks being deduplicated — and the write figures for real data are somewhere between the two extremes rather than at either."
    "* If you are comparing storage classes and only have time for one number, it is `fsync_8k_qd1` — or, if you would rather have one an application would recognise, the pgbench TPS in [pgbench](#pgbench)."
    "* fio measures the storage. [pgbench](#pgbench) measures what a database gets out of it, which is always less: the same commit that fio counts as one 8 KiB write is, in postgres, a WAL record, an fsync, a heap and index page to write back later, and a full-page image if a checkpoint has just been through. Where the two disagree about which mount is faster, pgbench is the one that resembles a workload."
    "* Latency columns are mean completion latency in microseconds. Bandwidth columns are KiB/s as reported by fio."
    "* The tables are whole-run averages. An average hides the shape of a run, and the shape is often the interesting part — a cache filling up, a throttle kicking in, a backend stalling. The time-series chart under each test in [fio tests](#fio-tests) is where that shows."
    ""
  ] | str join "\n"
}

# The capacity is a real Markdown table rather than a block of `df -h` output in
# a code fence, because it never was text — it is a row of numbers that the
# shell version had to render as text, parse nothing back out of, and paste in.
# The /proc/mounts line stays fenced: it is one line of kernel formatting and
# reformatting it would only lose the mount options.
def report-mounts [ctx: record]: nothing -> string {
  let sections = ($ctx.usable | each {|mp|
    let sl = (slug $mp)
    let capf = $"($ctx.mountinfo)/capacity_($sl).csv"
    let mntf = $"($ctx.mountinfo)/mount_($sl).txt"
    let cap = (if ($capf | path exists) {
      open --raw $capf | from csv | to md --pretty
    } else { "" })
    let mnt = (if ($mntf | path exists) { open --raw $mntf | str trim --right } else { "" })
    $"### ($mp)\n\n($cap)\n\n```text\n($mnt)\n```\n"
  })
  (["## Mount points" ""] | append $sections | str join "\n")
}

def report-fio-tests [ctx: record]: nothing -> string {
  let cfg = $ctx.cfg
  let intro = ([
    "## fio tests"
    ""
    $"($ctx.fio_tests | length) jobs, each isolating one thing the storage can be bad at. Every"
    "one of them is also given these flags, which are what make the numbers"
    "comparable:"
    ""
    "* `--direct=1` — O_DIRECT, so reads and writes go to the backend instead of"
    "  being served by the page cache. Without it most of these tests would be"
    "  measuring RAM."
    $"* `--time_based --runtime=($cfg.fio_runtime)` — each job runs for a fixed ($cfg.fio_runtime) seconds,"
    "  looping over its file if it finishes early. Every mount therefore gets equal"
    "  **time** rather than equal **bytes**, so a slow backend cannot shorten its own run."
    $"* `--ioengine=($cfg.ioengine)` — how I/O is submitted to the kernel; an asynchronous"
    "  engine such as the default `libaio` is what lets a queue depth above 1 mean"
    "  anything. The commit-latency test overrides it with `psync`, which blocks on"
    "  each write, because blocking is the thing it is measuring."
    "* `--group_reporting` — with more than one worker, report the aggregate rather"
    "  than each worker separately."
    "* `--directory` — the mount under test. It is the only flag that differs between"
    "  mounts — everything below is identical for all of them."
    ""
    "The command shown under each test is the one that ran, recorded as it ran, and"
    "below it is what the storage did while it ran."
    ""
    $"Every fio job logs itself as a time series, one sample per ($cfg.log_avg_msec)ms window, and"
    "that is what those charts are. The x axis is elapsed time **within that job**,"
    "so runs on different mounts line up even when they were minutes apart on the"
    "clock. Where a job does both reads and writes (`rand_rw_70_30_4k`) each"
    "direction is a separate line. Multi-job tests have their per-job samples summed"
    "for IOPS and bandwidth and averaged for latency, so the lines are the aggregate"
    "the tables report, not one worker's share of it. Latency uses a logarithmic y"
    "axis — storage latency spans orders of magnitude and a linear axis flattens"
    "everything below the worst spike into the baseline."
    ""
    "What to look for: a flat line is a backend holding its service level; a decaying"
    "curve is usually a cache or write buffer filling; periodic collapses to near"
    "zero are flush or compaction stalls, which the whole-run averages in the table"
    "below will not show you at all."
    $ctx.headline.note
    ""
  ] | str join "\n")

  let sections = ($ctx.fio_tests | each {|t|
    let args = ($ctx.fio_args | get $t | str join " ")
    [
      $"### ($t)"
      ""
      # The purpose blocks are raw strings that open with a newline, because a
      # raw string whose first character is `#` confuses the lexer into reading
      # it as part of the `r#'` delimiter.
      (fio-test-purpose $t | str trim)
      ""
      "```console"
      $"$ fio --directory=<mount> ($args)"
      "```"
      ""
      (emit-graphs $ctx $t $t $ctx.headline.graphs)
    ] | str join "\n"
  })

  ([$intro] | append $sections | str join "\n")
}

def report-pgbench [ctx: record, pg_rows: table, graphed: bool]: nothing -> string {
  let cfg = $ctx.cfg
  if not $ctx.caps.pgbench {
    return ([
      "## pgbench"
      ""
      r#'Not run. The suite normally finishes with a real workload — a throwaway
PostgreSQL cluster per mount, driven through pgbench's TPC-B-like transaction —
because it is the only number here that carries a WAL, a checkpointer and a
page cache rather than measuring the storage directly.

It was skipped: either `PGBENCH=0` was set, postgres is not in this image, the
benchmark is running as root (postgres refuses to), or the uid it runs as has
no `/etc/passwd` entry, which postgres needs to resolve its own identity. The
run summary printed at the end says which.
'#
    ] | str join "\n")
  }

  let prose = ([
    "Everything above measures the storage. This measures a database on top of it,"
    "which is the only number here an application would recognise."
    ""
    $"A throwaway PostgreSQL ($ctx.caps.pg_version) cluster is created on each mount with"
    $"`initdb`, loaded to scale ($cfg.pgbench_scale) \(about ($cfg.pgbench_scale * 16) MiB of table data before"
    $"indexes), warmed for ($cfg.pgbench_warmup)s and then driven for ($cfg.pgbench_time)s through pgbench's"
    $"built-in TPC-B-like workload at ($cfg.pgbench_clients) concurrent clients across ($cfg.pgbench_jobs) threads."
    "Each transaction is a handful of small updates and an insert, committed — so"
    "every one of them costs a WAL write and an `fsync` before the client is told"
    "it succeeded."
    ""
    $"The warmup is discarded. Measured from cold a pgbench run does not report the"
    $"workload, it reports the decay into it: the buffer cache starts empty, the WAL"
    $"has not yet wrapped, and no checkpoint has happened, so the first seconds are"
    $"faster than anything the storage can sustain. ($cfg.pgbench_warmup)s of unmeasured traffic puts"
    $"the cluster in the state it would be in after a few minutes of real use, and"
    $"the measured run then starts there. Its numbers are still in"
    $"`raw/<pass>/pgbench_<mount>.txt` if you want to see how far off the cold start"
    $"was. `--no-vacuum` on the measured run keeps that state rather than letting"
    $"pgbench's usual pre-run vacuum undo it."
    ""
    $"Statements go over the wire as `($cfg.pgbench_mode)` \(`PGBENCH_MODE`). pgbench"
    $"defaults to `simple`, which makes the server parse and plan every statement"
    $"again on each execution — at which point a good part of what is being measured"
    $"is postgres reading SQL rather than the storage underneath it. Real"
    $"applications, and every connection pooler, use prepared statements."
    ""
    r#'That commit path is why this tracks `fsync_8k_qd1` more closely than any other
test here, and why the two can still disagree: postgres adds a WAL record, a
heap and index page the checkpointer has to write back later, and a full-page
image for the first write to each page after a checkpoint. Write amplification
of several times the logical change is normal, and a backend that does well on
raw `fsync` but badly here is usually one that copes with a steady trickle of
small writes but not with the burst a checkpoint delivers.

The cluster runs with `fsync`, `synchronous_commit` and `full_page_writes` all
on, which are the defaults, stated so that what was measured is on the record.
'#
    $"`max_wal_size` is raised to ($cfg.pgbench_max_wal) from the 1 GB default: at 1 GB a mount that"
    $"absorbs writes quickly checkpoints every few seconds, which is a property of"
    $"the default rather than of any tuned database, and it dominates the run."
    $"`shared_buffers` is left at its 128 MB default on purpose, in the other"
    $"direction: a cluster large enough to cache the working set would be reporting"
    $"the speed of RAM. The cluster is deleted after each mount."
    ""
    r#'| Column | Meaning |
| ------ | ------- |
| `init_s` | seconds to load the data — bulk write throughput, as pgbench timed it |
| `tps` | transactions per second over the timed run, excluding connection setup |
| `latency_avg_ms` | mean time to commit one transaction |
| `failed` | transactions rolled back; anything but 0 makes `tps` suspect |
'#
  ] | str join "\n")

  let charts = (if $graphed {
    ([
      ""
      r#'pgbench aggregates its own log into fixed intervals and one second is the
finest it will accept, so these are coarser than the fio charts above — a stall
shorter than a second is inside a sample rather than visible as one. The worst
latency chart is the one to read for that: it plots the slowest single
transaction in each interval, so a checkpoint or an fsync stall that the mean
absorbs still shows as a spike.
'#
      (emit-graphs $ctx "pgbench" "pgbench" $ctx.headline.graphs)
    ] | str join "\n")
  } else { "" })

  [
    "## pgbench"
    ""
    $prose
    ($pg_rows | to md --pretty)
    $charts
  ] | str join "\n"
}

def report-passes [ctx: record, graphed: record]: nothing -> string {
  let cfg = $ctx.cfg
  # Only worth a section when there is more than one pass. With a single pass
  # its charts are already the ones sitting next to the prose above, and
  # repeating them here would just double the size of the HTML.
  if $cfg.repeats <= 1 or ($ctx.headline.graphs | is-empty) { return "" }

  let intro = ([
    ""
    "## Pass by pass"
    ""
    $"The charts above are the mean of ($cfg.repeats) passes. These are the passes"
    "themselves, in the order they ran, for when the aggregate hides something the"
    "mean should not have smoothed: a first pass that was slower than the rest"
    "because a cache was cold, or one pass that stalled and pulled the band wide on"
    "its own."
    ""
    "Each pass is a complete run of the suite, separated from the next by the same"
    $"($cfg.settle)s cooldown that separates runs within a pass."
    ""
  ] | str join "\n")

  let compare = (if $graphed.compare {
    # The leading newline is not cosmetic: a raw string whose first character is
    # `#` runs into the lexer counting it as part of the `r#'` delimiter.
    let head = r#'
### Every pass on one axis

Each chart here is one test with every pass drawn on it, unaggregated. The
colour is the series — the mount, and the direction where a test does both —
and the dash pattern is the pass, so the same series across passes stays
recognisably the same series.

This is the chart that says *which* pass disagreed, which the band on the
aggregate cannot: a first pass slower than the rest because a cache was cold
and one pass in three stalling at random produce the same width of band and
mean very different things.
'#
    let figs = (
      $ctx.fio_tests
      | each {|t| emit-graphs $ctx $t $t "compare" }
      | append (if $graphed.pgbench { emit-graphs $ctx "pgbench" "pgbench" "compare" } else { "" })
      | str join "\n"
    )
    $"($head)\n($figs)"
  } else { "" })

  let per_pass = ($ctx.run_ids | each {|rid|
    let figs = (
      $ctx.fio_tests
      | each {|t| emit-graphs $ctx $t $t $rid }
      | append (if $graphed.pgbench { emit-graphs $ctx "pgbench" "pgbench" $rid } else { "" })
      | str join "\n"
    )
    $"### ($rid)\n\n($figs)"
  } | str join "\n")

  [$intro $compare $per_pass] | str join "\n"
}

def report-raw [ctx: record]: nothing -> string {
  let headline = (if ($ctx.headline.graphs | is-empty) { "run-01" } else { $ctx.headline.graphs })
  [
    r#'
## Raw output

Everything a pass produced sits under that pass's own directory, `run-01`,
`run-02` and so on, because fio names its logs after the test rather than after
the attempt and a second pass would otherwise overwrite the first.

`raw/<pass>/` holds fio's terse lines, one file per test per mount. They are
terse version 3 records — useful if you want latency percentiles or bandwidth
min/max, which are not carried into the CSV above.
`raw/pgbench_<mount>.txt` in the same directory holds everything pgbench and
initdb printed, and `raw/<pass>/pgbench_<mount>_server.log` the postgres server
log for that mount — checkpoint and autovacuum activity land there, which is
usually where an unexplained dip in the transaction rate is explained. The
capacity and `/proc/mounts` captures are properties of the mount rather than of
a pass, so they sit above the per-pass directories in `raw/` itself, as
`capacity_<mount>.csv` and `mount_<mount>.txt`.

`fio-logs/<pass>/` holds fio's own time-series logs, named
`<mount>_<test>_{bw,iops,lat,slat,clat}.log`, in fio's usual
`time_ms, value, ddir, blocksize, offset` format (`ddir` 0 = read, 1 = write).
Bandwidth is KiB/s, latency is nanoseconds. Alongside them are pgbench's
aggregate logs, `pgbench_<mount>.<pid>[.<thread>]`, one row per second per
thread as `interval_start num_transactions sum_latency sum_latency_2
min_latency max_latency` with latencies in microseconds.

These are the unprocessed inputs to the charts above, and the fio ones are in
fio's standard log format, so `fio2gnuplot` and `fiologparser.py` will read them
if you want to re-plot them differently. Neither ships in this image — both are
Python, and CPython is most of what a benchmark image would otherwise carry.

`graphs/<pass>/` holds the rendered SVGs alongside the gnuplot script that drew
each one, and `graphs/data/<pass>/` the reduced series they were drawn from, so
any plot can be tweaked and redrawn without re-running the benchmark:
'#
    "```console"
    $"$ gnuplot graphs/($headline)/rand_read_4k_iops.gp"
    "```"
    ""
    "The aggregate charts are in `graphs/aggregate/`, drawn from"
    "`graphs/data/aggregate_*.dat`, whose columns are `time mean min max`."
  ] | str join "\n"
}

def write-report [
  ctx: record, results: record, elapsed: int, graphed: record
]: nothing -> string {
  let no_graphs = (if ($ctx.headline.graphs | is-empty) {
    if $ctx.caps.gnuplot {
      $"\nNo time-series samples were produced — every fio job failed, or the\nruns were shorter than one ($ctx.cfg.log_avg_msec)ms sample window.\n"
    } else {
      "\nGraphs were skipped: gnuplot is not available in this image, or\n`PLOT=0` was set. The underlying logs are still under `fio-logs/`\nand can be plotted after the fact.\n"
    }
  } else { "" })

  [
    (report-header $ctx $elapsed)
    (report-mounts $ctx)
    ""
    (report-fio-tests $ctx)
    ""
    "## fio results"
    ""
    "Rows appear in execution order."
    ""
    ($results.fio | to md --pretty)
    ""
    (report-pgbench $ctx $results.pgbench $graphed.pgbench)
    (report-passes $ctx $graphed)
    $no_graphs
    (report-raw $ctx)
  ]
  | str join "\n"
  # Sections are assembled from chunks that mostly end in a newline of their
  # own, and joining them adds another. Rather than have every chunk agree on
  # whether it terminates itself — which is what the shell version's `echo`s
  # are doing, by hand, at each of two dozen sites — the run of blank lines is
  # flattened once, here.
  | str replace --all --regex "\n{3,}" "\n\n"
}

# ---------------------------------------------------------------------------
# Render
#
# cmark-gfm turns the Markdown into an HTML fragment and nothing else — no
# document, no stylesheet, no table of contents, and no way to inline an image.
# It is chosen for exactly that: it is a ~1 MB C program with no dependencies
# beyond libc, where the alternatives are a Ruby or a Haskell runtime, either of
# which would be the largest thing in the image by a wide margin. The four
# things it does not do are done below instead — in the shell version, by a
# 100-line awk program held entirely in memory.
#
# The result is one self-contained file: the stylesheet is embedded and every
# graph is inlined as a data: URI, so the HTML can be mailed or copied out of a
# pod on its own without dragging graphs/ along with it.
# ---------------------------------------------------------------------------

# The page shell. Light and dark are both styled because this is read in a
# browser, but graph figures keep a white plate in either: the SVGs gnuplot
# writes have a hard-coded white background and black axis text, so they need
# one.
def html-head []: nothing -> string {
  r#'<!DOCTYPE html>
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
'#
}

# Anchors are GitHub-compatible — lowercased, punctuation dropped, spaces
# hyphenated, duplicates suffixed -1, -2 — so the intra-document links in the
# Markdown resolve both here and when the .md is viewed on a forge.
def slugify [s: string]: nothing -> string {
  $s
  | str replace --all --regex '<[^>]*>' ''
  | str replace --all --regex '&[#0-9a-zA-Z]+;' ''
  # `str downcase` on the pinned nixpkgs' Nushell 0.112; renamed to
  # `str lowercase` in 0.114, which warns about this one and has not removed it
  # yet. Rename it when the pin moves — running this file under a newer Nushell
  # than the image ships is what produces that warning.
  | str downcase
  | str replace --all --regex '[^a-z0-9 _-]' '-'
  | str replace --all --regex ' +' '-'
  | str replace --all --regex '-+' '-'
  | str replace --regex '^-' ''
  | str replace --regex '-$' ''
}

def inline-uris [line: string, uris: record]: nothing -> string {
  if not ($line | str contains 'src="graphs/') { return $line }
  $uris | items {|k, v| { k: $k, v: $v } } | reduce --fold $line {|e, acc|
    $acc | str replace --all $"src=\"($e.k)\"" $"src=\"($e.v)\""
  }
}

# cmark-gfm's fragment, plus the four things it leaves out: heading ids,
# section numbers, a table of contents, and inlined images. The whole fragment
# is held in memory because the contents page has to be printed before the body
# it was built from.
def decorate [fragment: string, uris: record]: nothing -> string {
  let lines = ($fragment | lines)

  # ---- first pass: find the headings ------------------------------------
  mut seen = {}
  mut n2 = 0
  mut n3 = 0
  mut heads = {}
  mut toc = []

  for i in 0..(($lines | length) - 1) {
    let l = ($lines | get $i)
    if not ($l =~ '^<h[23][^>]*>') { continue }

    let lvl = ($l | parse --regex '^<h([23])' | get 0.capture0 | into int)
    let inner = ($l
      | str replace --regex '^<h[23][^>]*>' ''
      | str replace --regex '</h[23]>\s*$' '')

    let raw_slug = (slugify $inner)
    let base = (if ($raw_slug | is-empty) { "section" } else { $raw_slug })
    let n = ($seen | get --optional $base | default 0)
    let id = (if $n == 0 { $base } else { $"($base)-($n)" })
    $seen = ($seen | upsert $base ($n + 1))

    if $lvl == 2 { $n2 = $n2 + 1; $n3 = 0 } else { $n3 = $n3 + 1 }
    let num = (if $lvl == 2 { $"($n2)." } else { $"($n2).($n3)." })

    $heads = ($heads | upsert $"l($i)" { lvl: $lvl, id: $id, num: $num, txt: $inner })
    $toc = ($toc | append $"<li class=\"toc-l($lvl)\"><a href=\"#($id)\"><span class=\"secnum\">($num)</span>($inner)</a></li>")
  }

  # ---- second pass: emit -------------------------------------------------
  mut out = ["<nav id=\"toc\" aria-label=\"Contents\">" "<p class=\"toc-title\">Contents</p>"]
  if ($toc | is-not-empty) {
    $out = ($out | append "<ul>" | append $toc | append "</ul>")
  }
  $out = ($out | append "</nav>" | append "<main id=\"content\">")

  for i in 0..(($lines | length) - 1) {
    let l = ($lines | get $i)
    let h = ($heads | get --optional $"l($i)")

    if $h != null {
      $out = ($out | append $"<h($h.lvl) id=\"($h.id)\"><span class=\"secnum\">($h.num)</span>($h.txt)</h($h.lvl)>")
      continue
    }

    # A paragraph containing nothing but an image becomes a captioned figure,
    # with the alt text serving as the caption.
    if ($l =~ '^<p><img [^>]*/></p>$') {
      let img = ($l | str replace --regex '^<p>' '' | str replace --regex '</p>$' '')
      let alt = ($img | parse --regex 'alt="([^"]*)"' | get --optional 0.capture0 | default "")
      let cap = (if ($alt | is-empty) { "" } else { $"<figcaption>($alt)</figcaption>" })
      let inlined = (inline-uris $img $uris)
      $out = ($out | append $"<figure>($inlined)($cap)</figure>")
      continue
    }

    # Wide tables (fio results is eight columns) scroll inside their own box
    # rather than pushing the page sideways.
    if $l == "<table>" {
      $out = ($out | append "<div class=\"tablewrap\">" | append $l)
      continue
    }
    if $l == "</table>" {
      $out = ($out | append $l | append "</div>")
      continue
    }

    $out = ($out | append (inline-uris $l $uris))
  }

  $out | append "</main>" | str join "\n"
}

def render-html [ctx: record, md: path, out: path]: nothing -> bool {
  # base64 rather than inlining the SVG markup: gnuplot gives every plot the
  # same element ids, and a dozen inline <svg> blocks sharing one id space would
  # have each of them resolve its <defs> references to the first plot on the
  # page. A data: URI keeps each graph in its own document, as a separate file
  # would have.
  #
  # The SVGs live one directory down, under the pass that drew them, so the key
  # has to be the path relative to OUTDIR — which is what the Markdown refers to
  # them by — rather than just the basename. Every pass names its charts
  # identically, so a basename key would collide and every pass would show the
  # first pass's graphs.
  #
  # No temporary map file and no `base64 -w0`: `encode base64` is a builtin, and
  # the map is a record that stays in memory.
  let uris = (
    glob $"($ctx.plotdir)/*/*.svg"
    | reduce --fold {} {|f, acc|
        let rel = ($f | str replace $"($ctx.outdir)/" "")
        $acc | upsert $rel $"data:image/svg+xml;base64,(open --raw $f | encode base64)"
      }
  )

  let frag = (^cmark-gfm --unsafe -e table -e autolink $md | complete)
  if $frag.exit_code != 0 { return false }

  [(html-head) (decorate $frag.stdout $uris) "</body>\n</html>\n"]
  | str join "\n"
  | save --raw --force $out

  file-has-content $out
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Anything a pass produces is written under its own directory, because a second
# pass would otherwise overwrite the first: fio names its logs after the test,
# not after the attempt.
#
# Run ids are zero-padded so that graphs/ and raw/ sort in execution order in a
# file browser rather than putting run-10 next to run-1.
def run-paths [ctx: record, pass: int]: nothing -> record {
  let rid = (run-id-for $pass)
  let paths = {
    run_id: $rid
    rawdir: $"($ctx.outdir)/raw/($rid)"
    logdir: $"($ctx.outdir)/fio-logs/($rid)"
    plotdata: $"($ctx.plotdir)/data/($rid)"
  }
  mkdir $paths.rawdir $paths.logdir $paths.plotdata
  $paths
}

# The shell version's EXIT trap, minus the signal handling Nushell does not
# have. The PG_VERSION test is what makes the recursive delete safe: it fires
# only on a directory postgres itself created, never on a mount point that a bad
# expansion happened to name.
def cleanup [ctx: record] {
  print ""
  print "Cleaning up test files..."
  for mp in $ctx.usable {
    for f in [fio_seq.dat fio_seq_zero.dat fio_seq_rand.dat fio_rand.dat fio_mix.dat fio_sync.dat] {
      rm --force $"($mp)/($f)"
    }
    let pgdata = $"($mp)/pgdata"
    if ($"($pgdata)/PG_VERSION" | path exists) { rm --recursive --force $pgdata }
  }
  if ($ctx.caps.sockdir | is-not-empty) { rm --recursive --force $ctx.caps.sockdir }
}

def append-row [file: path, row: record] {
  [$row] | to csv --noheaders | save --raw --append $file
}

def main [...mounts: string] {
  if ($mounts | is-empty) {
    print --stderr "Usage: storage-bench.nu <mount1> [<mount2> ...]"
    exit 1
  }

  let ts = (date now | format date '%Y%m%d-%H%M%S')
  let cfg = (load-config $ts)
  let caps = (preflight $cfg)

  let usable = (usable-mounts $mounts $caps.uid)
  if ($usable | is-empty) {
    print --stderr "No usable mount points. Nothing to do."
    exit 1
  }

  # Capacity and /proc/mounts are properties of the mount rather than of a
  # pass, so they are captured once and live above the per-pass directories.
  let mountinfo = $"($cfg.outdir)/raw"
  let plotdir = $"($cfg.outdir)/graphs"
  mkdir $mountinfo $plotdir

  let fio_args = (fio-job-args $cfg)
  let run_ids = (1..$cfg.repeats | each {|n| run-id-for $n })

  let ctx = {
    cfg: $cfg
    caps: $caps
    usable: $usable
    outdir: $cfg.outdir
    plotdir: $plotdir
    mountinfo: $mountinfo
    fio_args: $fio_args
    fio_tests: ($TESTS | where {|t| $t in ($fio_args | columns) })
    run_ids: $run_ids
    # Filled in after the graphs are drawn; the report functions read it.
    headline: { graphs: "", suffix: "", note: "" }
  }

  print $"Benchmarking : ($usable | str join ' ')"
  print $"Run order    : ($cfg.order)"
  print $"Settle       : ($cfg.settle)s between runs, ($cfg.test_settle)s between tests"
  print $"Results dir  : ($cfg.outdir)"

  for mp in $usable {
    let sl = (slug $mp)
    # /proc/mounts rather than mount(8): the same device/fstype/options in the
    # same fstab columns, and it keeps util-linux out of the image entirely,
    # which was ~25 MB once its PAM and systemd links are counted. There is no
    # mount(8) fallback any more — /proc is not optional here, it is where the
    # uid, the hostname and the kernel version come from too.
    #
    # The line kept is the one for the filesystem the path is *on*, not every
    # line containing the path as a substring. The shell version grepped, which
    # answers correctly when the mount point is the path under test and answers
    # nothing at all when it is a directory inside one.
    let owner = (owning-mount $mp)
    capacity-of $owner | to csv | save --raw --force $"($mountinfo)/capacity_($sl).csv"
    $"($owner.line)\n" | save --raw --force $"($mountinfo)/mount_($sl).txt"
  }

  let fio_csv = $"($cfg.outdir)/fio_results.csv"
  let pg_csv = $"($cfg.outdir)/pgbench_results.csv"
  let md = $"($cfg.outdir)/storage-benchmark-report.md"

  # The header lines are written up front and each row is appended as it is
  # produced, so an hour-long run that dies in the fifty-ninth minute still
  # leaves the results it had. The in-memory table below is what the report is
  # built from.
  "run,mount,test,read_iops,read_bw_kibs,read_clat_mean_us,write_iops,write_bw_kibs,write_clat_mean_us\n" | save --raw --force $fio_csv
  if $caps.pgbench {
    "run,mount,scale,clients,threads,mode,warmup_s,duration_s,init_s,tps,latency_avg_ms,transactions,failed\n" | save --raw --force $pg_csv
  }

  let start = (date now)

  let results = (try {
    1..$cfg.repeats | each {|pass|
      let paths = (run-paths $ctx $pass)

      if $cfg.repeats > 1 {
        log-section $"pass ($pass) of ($cfg.repeats) \(($paths.run_id))"
        # The same cooldown that separates runs within a pass separates the
        # passes themselves, so pass 2 does not start measuring while the
        # backend is still flushing what pass 1 wrote.
        if $pass > 1 { settle $cfg }
      }

      let rows = (if $cfg.order == "by-mount" {
        $usable | enumerate | each {|m|
          if $m.index > 0 {
            log-section "cooldown between mounts"
            settle $cfg
          }
          log-section $m.item
          # The gap between consecutive tests on one mount. Without it a test
          # begins while the previous one's writeback is still in flight, and
          # that shows up in its first samples as the storage being slower than
          # it is.
          $TESTS | enumerate | each {|t|
            if $t.index > 0 { test-settle $cfg }
            run-test $ctx $paths $m.item $t.item
          }
        } | flatten
      } else {
        $TESTS | enumerate | each {|t|
          log-section $t.item
          $usable | enumerate | each {|m|
            # by-test already pauses between every (test, mount) unit, and
            # SETTLE is longer than TEST_SETTLE would be, so nothing is added.
            if $t.index > 0 or $m.index > 0 { settle $cfg }
            info $"-> ($m.item)"
            run-test $ctx $paths $m.item $t.item
          }
        } | flatten
      })

      $rows | each {|r|
        append-row (if $r.kind == "fio" { $fio_csv } else { $pg_csv }) $r.row
        $r
      }
    } | flatten
  } catch {|e|
    cleanup $ctx
    error make --unspanned { msg: $"benchmark failed: ($e.msg)" }
  })

  let elapsed = ((((date now) - $start) | into int) // 1_000_000_000)

  let by_kind = {
    fio: ($results | where kind == "fio" | each {|r| $r.row })
    pgbench: ($results | where kind == "pgbench" | each {|r| $r.row })
  }

  let graphed = (draw-graphs $ctx)

  # Which set of charts belongs next to the prose. With more than one pass that
  # is the aggregate — the mean is the summary you want beside the explanation,
  # and the individual passes are detail that goes at the end. With one pass
  # there is no aggregate and the one pass is itself the headline.
  let headline = (if $cfg.repeats > 1 and $graphed.aggregate {
    {
      graphs: "aggregate"
      suffix: $" \(mean of ($cfg.repeats) passes)"
      note: $"
The suite ran ($cfg.repeats) times. Each chart below is the mean across those passes,
with the band behind it spanning the slowest and fastest pass at that moment —
so the line is what to expect and the width of the band is how much the storage
disagreed with itself. A band that stays narrow is a backend under control; one
that flares is a backend whose behaviour depends on something not being
measured here. The passes are also plotted separately in
[pass by pass]\(#pass-by-pass)."
    }
  } else if ($run_ids | is-not-empty) and (glob $"($plotdir)/($run_ids | first)/*.svg" | is-not-empty) {
    { graphs: ($run_ids | first), suffix: "", note: "" }
  } else {
    { graphs: "", suffix: "", note: "" }
  })

  let ctx = ($ctx | upsert headline $headline)

  log-section "Writing report"
  let report = (write-report $ctx $by_kind $elapsed $graphed)
  $"($report)\n" | save --raw --force $md

  mut html = ""
  if $caps.render == "html" {
    log-section "Rendering report"
    info "HTML ..."
    let out = $"($cfg.outdir)/storage-benchmark-report.html"
    if (try { render-html $ctx $md $out } catch { false }) {
      $html = $out
    } else {
      info "  FAILED"
    }
  }

  cleanup $ctx

  # A finished run is a few thousand files, and the machine it was measured on
  # is usually not the one it gets read on, so it is tarred up as the last thing
  # before the summary. The archive is written next to the run directory rather
  # than inside it, so it does not have to exclude itself and so a second run's
  # archive does not disappear into the first one's folder.
  #
  # With RUNDIR empty the run directory *is* OUTBASE and there is no "next to",
  # so the archive goes inside and tar is handed the top-level entries by name.
  # Excluding it from a walk of `.` is not enough: tar still stats the directory
  # it is writing into, sees it change underneath itself, and exits 1 with "file
  # changed as we read it", which is indistinguishable from a real failure.
  let archive = (if $cfg.archive and (has-cmd "tar") {
    log-section "Archiving results"
    let spec = (if ($cfg.rundir | is-empty) {
      let a = $"($cfg.outdir)/storage-bench-results.tar.gz"
      let entries = (ls $cfg.outdir | get name | path basename | where {|e| $e != "storage-bench-results.tar.gz" })
      { path: $a, args: ([-C $cfg.outdir] | append $entries) }
    } else {
      let base = ($cfg.outdir | path dirname)
      { path: $"($base)/($cfg.rundir).tar.gz", args: [-C $base $cfg.rundir] }
    })
    let r = (^tar -czf $spec.path ...$spec.args | complete)
    if $r.exit_code == 0 {
      info $"($spec.path)"
      $spec.path
    } else {
      info $"FAILED: ($r.stderr | str trim)"
      ""
    }
  } else { "" })

  let last = (run-id-for $cfg.repeats)
  print ""
  print $"Done in ($elapsed)s."
  if ($archive | is-not-empty) { print $"  Archive  : ($archive)" }
  print $"  Report   : ($md)"
  if ($html | is-not-empty) { print $"             ($html)" }
  print $"  CSVs     : ($fio_csv)"
  if $caps.pgbench { print $"             ($pg_csv)" }
  if $caps.gnuplot { print $"  Graphs   : ($plotdir)/" }
  print $"  fio logs : ($cfg.outdir)/fio-logs/($last)/"
  print $"  Raw      : ($cfg.outdir)/raw/($last)/"

  # Repeated here because the notes above were printed before a run that may
  # have taken an hour, and an incomplete report is worth noticing now rather
  # than after the machine under test has moved on.
  if ($caps.missing | is-not-empty) {
    print ""
    print "WARNING: this report is incomplete — tools missing from PATH:"
    $caps.missing | each {|m| print $"  - ($m)" } | ignore
    print ""
    print "  The container image ships all of them. On a host, nix-shell does too:"
    print $"    nix-shell --run 'nu storage-bench.nu ($usable | str join ' ')'"
    print "  Set PLOT=0 / RENDER=none to make the omission deliberate and silent."
  }

  if ($html | is-empty) {
    print ""
    print $"The Markdown is readable as it stands. To render it elsewhere, from ($cfg.outdir)"
    print "so that the relative graphs/ paths resolve:"
    print "  pandoc -s --toc --embed-resources -o report.html storage-benchmark-report.md"
    print "  pandoc -o report.pdf storage-benchmark-report.md   # -> PDF, needs a TeX engine"
  }
}
