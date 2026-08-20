# The runtime closure storage-bench.sh needs, shared by the container image
# (default.nix) and the host shell (shell.nix) so the two cannot drift apart.
#
# Drift is the reason this is its own file: a host run that is missing gnuplot
# still completes the benchmark, it just silently produces a report with no
# graphs in it — the kind of difference you notice an hour after the run.
#
# Most of what is here is a trimmed variant rather than the stock package.
# Stock fio, gnuplot and asciidoctor carry optional features this benchmark
# never touches, and between them they were three quarters of the image. Each
# override below says what it drops and what would notice; `just size` is what
# tells you whether it is still true after a nixpkgs bump.

pkgs:

let
  inherit (pkgs) lib;

  # fio installs five Python helper scripts next to its binaries — fio2gnuplot,
  # fiologparser*, fio_jsonplus_clat2csv — and nixpkgs wraps them, which pins
  # CPython into the closure at ~130 MB. The script calls none of them: it
  # drives gnuplot itself, because fio2gnuplot plots one file pattern per chart
  # rather than overlaying the mounts under test on shared axes. libnbd goes the
  # same way: it is fio's network-block-device ioengine, useless against a
  # mounted filesystem, and it drags in gnutls and p11-kit.
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

  # The script plots with `set terminal svg`, which gnuplot implements itself —
  # it writes markup and lets the browser do the drawing, so it needs no
  # graphics library at all. Everything a rasterising terminal would need comes
  # off: libgd and its libavif AV1 codecs (~25 MB) for the png/gif/jpeg/sixel
  # terminals, cairo/pango/glib/harfbuzz/freetype/fontconfig (~30 MB) for the
  # *cairo ones, the X11 client libraries for the interactive x11 terminal, and
  # the DejaVu font and fonts.conf that fontconfig needed to find a face.
  #
  # What survives: svg, dumb, canvas, postscript and the LaTeX terminals. What
  # is gone: png, pngcairo, pdfcairo, gif, jpeg, sixel, x11. If a .gp file under
  # graphs/ is ever changed to one of those, this is why gnuplot answers
  # "unknown or ambiguous terminal type".
  gnuplot = pkgs.gnuplot.overrideAttrs (old: {
    buildInputs = lib.filter
      (p: !(lib.elem (lib.getName p) [
        "gd"
        "cairo"
        "pango"
        "fontconfig"
        "libx11"
        "libxpm"
        "libxt"
        "libxaw"
      ]))
      old.buildInputs;
    configureFlags = [ "--without-x" "--without-qt" "--without-aquaterm" ];
    # Upstream's postInstall wraps gnuplot to set GDFONTPATH, which only the
    # libgd terminals read. Without libgd there is nothing left to wrap.
    postInstall = "";
  });

  # CRuby ships a pile of gems inside the interpreter, and an image scanner
  # reports a CVE against every one of them whether or not anything can reach
  # it. Deleting the ones nothing here uses is a fix rather than a suppression:
  # the vulnerable code is not in the image, so it stays fixed even if some
  # future code path tries to require it. The price is a Ruby build from source
  # — a store path cannot be edited after the fact.
  #
  # Two kinds, removed differently. "Bundled" gems are ordinary gems that live
  # under gems/; these four are mail and file-transfer clients that a container
  # converting AsciiDoc to HTML has no business carrying, and net-imap is what
  # prompted this (CVE-2026-42257, IMAP command injection via CRLF, CVSS 9.8).
  # net-http and net-protocol stay: open-uri needs them, and open-uri is how
  # asciidoctor resolves an `include::` or an image over http.
  #
  # "Default" gems like erb live in the stdlib tree with a stub gemspec, so they
  # take a different set of paths. erb (CVE-2026-41316) is reachable from
  # asciidoctor only through its custom-template converter, which needs -T on
  # the command line; the script never passes it. Dropping erb is what makes
  # `asciidoctor -T` unavailable in this image — put it back by deleting the
  # erb lines below.
  ruby = pkgs.ruby.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      gemDir=$out/${old.passthru.gemPath}

      for gem in net-imap net-pop net-smtp net-ftp; do
        rm -rf "$gemDir"/gems/"$gem"-*
        rm -f "$gemDir"/specifications/"$gem"-*.gemspec
        rm -f "$gemDir"/cache/"$gem"-*.gem
      done

      # The globs cover the version and architecture directories, e.g.
      # lib/ruby/3.4.0 and lib/ruby/3.4.0/x86_64-linux, without naming either.
      rm -f "$gemDir"/specifications/default/erb-*.gemspec
      rm -rf $out/lib/ruby/*/erb.rb $out/lib/ruby/*/erb $out/lib/ruby/*/*/erb
      rm -f $out/bin/erb
    '';
  });

  # nixpkgs' asciidoctor is a bundle: asciidoctor-pdf, prawn, a PDF reader, and
  # three syntax highlighters, one of which (pygments.rb) shells out to CPython
  # and so pins the same ~130 MB interpreter fio did. The report is rendered to
  # HTML and nothing else, and plain asciidoctor is a single gem with no gem
  # dependencies at all, so this is that one gem and a bundler wrapper.
  #
  # Nothing here highlights source blocks — the report has none. Nothing here
  # produces a PDF either; RENDER=pdf is gone from the script and the .adoc is
  # kept so a host with asciidoctor-pdf can still make one.
  #
  # Bumping it: take version and sha256 from the same nixpkgs revision that
  # nixpkgs.nix pins, out of pkgs/by-name/as/asciidoctor/gemset.nix. The version
  # has to match in both places below or bundler refuses to resolve.
  asciidoctorVersion = "2.0.26";
  asciidoctor = pkgs.bundlerApp {
    pname = "asciidoctor";
    exes = [ "asciidoctor" ];
    # The trimmed interpreter above, not pkgs.ruby. bundlerEnv rebuilds bundler
    # against whatever it is given, so the image ends up with one Ruby, not two.
    inherit ruby;

    gemfile = pkgs.writeText "Gemfile" ''
      source 'https://rubygems.org'
      gem 'asciidoctor'
    '';

    lockfile = pkgs.writeText "Gemfile.lock" ''
      GEM
        remote: https://rubygems.org/
        specs:
          asciidoctor (${asciidoctorVersion})

      PLATFORMS
        ruby

      DEPENDENCIES
        asciidoctor

      BUNDLED WITH
         2.7.2
    '';

    gemset = {
      asciidoctor = {
        groups = [ "default" ];
        platforms = [ ];
        source = {
          remotes = [ "https://rubygems.org" ];
          sha256 = "1hbin3j8wynl2fpqa3d6vb932pyngyfn8j2q6gbbn1n23z7srqqn";
          type = "gem";
        };
        version = asciidoctorVersion;
      };
    };
  };
in
{
  # Everything storage-bench.sh shells out to, plus the tool that renders its
  # report. gawk/gnugrep parse fio's terse output and dd's summary line, gnused
  # strips the unit off dd's elapsed time, and gawk also folds fio's time-series
  # logs into the per-series data files that gnuplot draws.
  #
  # coreutils covers more than it looks: `df` for the per-mount capacity in the
  # report and `uname -n` for its host header, which is why there is no
  # hostname(1) here. The mount table comes from /proc/mounts, which is why
  # there is no util-linux either — it was carried for that one command, and
  # the full build links PAM, systemd and shadow behind it.
  packages = [
    fio
    gnuplot
    asciidoctor
  ] ++ (with pkgs; [
    bashInteractive
    coreutils
    gawk
    gnugrep
    gnused
  ]);
}
