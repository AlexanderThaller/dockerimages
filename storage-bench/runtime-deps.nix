# The runtime closure storage-bench.sh needs, shared by the container image
# (default.nix) and the host shell (shell.nix) so the two cannot drift apart.
#
# Drift is the reason this is its own file: a host run that is missing
# cmark-gfm or typst still completes the benchmark, it just silently produces a
# report that was never rendered — the kind of difference you notice an hour
# after the run.
#
# fio is a trimmed variant rather than the stock package. Stock, it carries
# optional features this benchmark never touches. The override below says
# what it drops and what would notice; `just size` is what tells you whether
# it is still true after a nixpkgs bump.
#
# gnuplot used to be here too, for the graphs. It is not any more: the graphs
# are drawn by gawk itself now (render-chart.awk, materialised by
# storage-bench.sh at runtime), the same way storage-chaos.sh has always drawn
# its own — no rasteriser, no SVG terminal, one less package in the closure.

pkgs:

let
  # fio installs five Python helper scripts next to its binaries — fio2gnuplot,
  # fiologparser*, fio_jsonplus_clat2csv — and nixpkgs wraps them, which pins
  # CPython into the closure at ~130 MB. The script calls none of them: it
  # draws its own charts (render-chart.awk), overlaying the mounts under test
  # on shared axes, which fio2gnuplot does not do — it plots one file pattern
  # per chart. libnbd goes the same way: it is fio's network-block-device
  # ioengine, useless against a mounted filesystem, and it drags in gnutls and
  # p11-kit.
  #
  # `fio --enghelp` in the image no longer lists nbd. The logs under fio-logs/
  # are still fio's standard format, so the Python tools read them fine on a
  # host that has them — the report says as much.
  fio = (pkgs.fio.override { withLibnbd = false; }).overrideAttrs (_: {
    postInstall = ''
      rm -rf $out/share/fio
      rm -f $out/bin/fio2gnuplot $out/bin/fio_jsonplus_clat2csv \
            $out/bin/fiologparser.py $out/bin/fiologparser_hist.py \
            $out/bin/fio-histo-log-pctiles.py
    '';
  });

  # The report is Markdown, and this is what turns it into HTML: GitHub's
  # CommonMark implementation, a ~1 MB C library and a CLI on top of it, with no
  # dependency beyond libc — which coreutils has already put in the image.
  # Stock, with no override, because there is nothing in it to take out.
  #
  # It is the whole reason the report is Markdown rather than AsciiDoc. The
  # AsciiDoc renderer was asciidoctor, and asciidoctor is a Ruby program: the
  # image carried a CRuby interpreter, bundler and a gem environment — the
  # largest single thing in it after fio — to convert one document, and CRuby's
  # bundled gems meant a rolling supply of scanner CVEs against mail and
  # templating code no code path here could reach. Both are now simply absent.
  #
  # What comes with that is that cmark-gfm renders a fragment and nothing else:
  # no document, no stylesheet, no table of contents, no section numbers and no
  # way to inline an image. storage-bench.sh does those four itself, in awk, in
  # its `decorate` function — that is where to look if the HTML comes out
  # unstyled or without a contents pane.
  #
  # `-e table` is what makes the results CSVs render as tables; it is a GFM
  # extension rather than CommonMark, so plain `cmark` will not do.
  cmark-gfm = pkgs.cmark-gfm;

  # Renders the same Markdown as storage-benchmark-report.pdf. This is the one
  # dependency here whose size is not an afterthought: a single static Rust
  # binary that takes the image from 133 MB to 178 MB. It is 45 MB rather than
  # the 51 MB it costs storage-chaos because the openssl typst links — for a
  # package registry this image never reaches — is already here behind
  # postgresql. `just size` is what says whether that holds after a bump.
  #
  # It is here because everything else that produces a PDF is worse by a wide
  # margin. Measured against this same pin, on top of the closure as it stood:
  # pandoc is +233 MB and still needs an engine underneath it (+276 MB with
  # typst as that engine — a Haskell runtime whose job is to reach typst),
  # weasyprint is +260 MB of Python and would have doubled the image,
  # wkhtmltopdf is +153 MB of unmaintained WebKit, and headless chromium is
  # +1.7 GB. Only lowdown piped into `groff -Tpdf` beats it, at +12 MB — and
  # roff has no way to place an SVG, which would cost the report all 135 of
  # its charts.
  #
  # typst reads those charts itself, because resvg is built into it. That is
  # what keeps this to one package: no rasteriser, no librsvg, and no second
  # renderer that has to agree with render-chart.awk about what a chart looks
  # like. The crosshair script baked into each SVG is ignored, which is the
  # right answer for paper.
  typst = pkgs.typst;

  # The non-synthetic half of the benchmark. pgbench ships inside the main
  # postgresql output, so this one package covers initdb, the server and the
  # client the script drives.
  #
  # It is easily the largest thing in the image and every flag below is off
  # because a throwaway cluster on a unix socket, created and dropped inside a
  # single run of this script, cannot reach the feature:
  #
  #   gss       Kerberos. Pulls krb5. Nothing authenticates; initdb uses trust.
  #   icu       collation provider. 84 MiB of closure for locale-aware sorting
  #             that the script opts out of anyway — initdb runs with
  #             --locale=C, and the C locale is handled by libc.
  #   pam       PAM auth. Pulls linux-pam, and behind it Berkeley DB and
  #             systemd's libraries — ~100 MiB for a login path with no login.
  #   systemd   sd_notify readiness. The script waits with `pg_ctl -w`.
  #   jit       LLVM expression JIT. pgbench's transaction is five short
  #             statements; there is nothing to compile, and postgres would not
  #             reach its jit_above_cost threshold on any of them.
  #   curl, ldap, nls
  #             OAuth validation, directory auth, translated messages.
  #
  # Stock this is 144 MiB of closure; as configured it is 92.7 MiB, of which
  # ~43 MiB is new to the image — the rest is glibc and friends that coreutils
  # already brought. readline is deliberately *kept*, even though nothing here
  # runs psql interactively: dropping it saves 4.3 MiB and takes line editing
  # out of the psql you get from `just shell`, which is a bad trade.
  #
  # If a future change needs a real authentication method, a non-C collation or
  # a network listener, the flag it needs is here rather than somewhere else.
  postgresql = pkgs.postgresql.override {
    gssSupport = false;
    icuSupport = false;
    pamSupport = false;
    systemdSupport = false;
    jitSupport = false;
    curlSupport = false;
    ldapSupport = false;
    nlsSupport = false;
  };
in
{
  # Everything storage-bench.sh shells out to, plus the tool that renders its
  # report. gawk/gnugrep parse fio's terse output and pick the mount under test
  # out of /proc/mounts, gnused pulls the figures out of pgbench's summary, and
  # gawk also folds fio's time-series logs into the per-series data files —
  # and now draws the SVGs from them too (render-chart.awk), and assembles the
  # HTML around cmark-gfm's output.
  #
  # coreutils covers more than it looks: `df` for the per-mount capacity in the
  # report, and `uname -n` for its host header, which is why there is no
  # hostname(1) here. It is no longer here for `dd` — the three dd tests are
  # two fio jobs now — but the rest of that list keeps it. The mount table
  # comes from /proc/mounts, which is why there is no util-linux either: it
  # was carried for that one command, and the full build links PAM, systemd
  # and shadow behind it.
  packages = [
    fio
    cmark-gfm
    typst
    postgresql
  ] ++ (with pkgs; [
    bashInteractive
    coreutils
    gawk
    gnugrep
    gnused

    # A finished run is a directory of a few thousand files — per-pass fio logs,
    # reduced series, one SVG per chart per pass — and getting it off the
    # machine that was measured usually means scp or `kubectl cp`. Both are far
    # happier with one file, so the run is tarred up at the end. Together they
    # add 4.7 MiB to the closure and neither pulls anything but libc.
    gnutar
    gzip
  ]);
}
