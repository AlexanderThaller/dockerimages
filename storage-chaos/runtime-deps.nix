# The runtime closure storage-chaos.sh needs, shared by the container image
# (default.nix) and the host shell (shell.nix) so the two cannot drift apart.
#
# Drift is the reason this is its own file, the same reason it is one in
# storage-bench: a host run missing cmark-gfm or typst still kills every pod
# it was going to and then hands back a report that was never rendered — the
# kind of difference you notice after the cluster has already been disturbed.

pkgs:

let
  # The only thing here that talks to a cluster. Stock: it is a single static
  # Go binary with no closure to speak of, and there is no build flag that
  # would take anything useful out of it.
  #
  # `oc` would work too — the script only uses `get pods`, `delete pod` and
  # `auth can-i`, which are plain Kubernetes verbs — and KUBECTL='oc ...' picks
  # it up on a host that has it. It is not in the image because openshift's
  # client is several times the size for no verb this needs.
  kubectl = pkgs.kubectl;

  # Renders report.md into the single self-contained report.html. Same choice
  # and same reasoning as storage-bench: a ~1 MB C library whose only
  # dependency is the libc coreutils already brought, where the alternative was
  # a Ruby interpreter to convert one document.
  #
  # `-e table` is what makes the timeline and per-component tables render; it
  # is a GFM extension rather than CommonMark, so plain `cmark` will not do,
  # and `--unsafe` is what lets the inline SVG through.
  cmark-gfm = pkgs.cmark-gfm;

  # Renders the same report.md as report.pdf. The one dependency here whose
  # size is not an afterthought: a single static Rust binary that takes the
  # image from 142 MB to 196 MB, 42 MB of it typst and 9 MB the openssl it
  # links for a package registry this image never reaches. The font below
  # takes it to 198 MB. `just size` is what says whether those are still the
  # numbers after a nixpkgs bump.
  #
  # It is here because everything else that produces a PDF is worse by a wide
  # margin. Measured against this same pin, on top of the closure as it stood:
  # pandoc is +233 MB and still needs an engine underneath it (+276 MB with
  # typst as that engine — a Haskell runtime whose job is to reach typst),
  # weasyprint is +260 MB of Python, wkhtmltopdf is +153 MB of unmaintained
  # WebKit, and headless chromium is +1.7 GB. Only lowdown piped into
  # `groff -Tpdf` beats it, at +12 MB — and roff has no way to place an SVG,
  # which would cost the report all four of its charts.
  #
  # typst reads those charts itself, because resvg is built into it. That is
  # what keeps this to one package: no rasteriser, no librsvg, and no second
  # renderer that has to agree with the *_svg functions about what a chart
  # looks like.
  typst = pkgs.typst;

  # Fira Sans, four faces of it, for the PDF. The stock package is 98 MB: 92
  # OpenType files and the same 92 again as TrueType, every weight from Hair
  # to Ultra with an italic each, where this report sets one family and asks
  # it for regular, italic, bold and bold italic. Those four are 2 MB, and
  # typst has to open every font it is pointed at before it can lay out a
  # page, so the other 180 cost start-up time as well as image.
  #
  # A copy rather than an override because there is no build to hook: the
  # package unpacks an archive of fonts and installs all of them.
  fira-sans = pkgs.runCommand "fira-sans-report" { } ''
    mkdir -p $out/share/fonts/opentype
    for f in Regular Italic Bold BoldItalic; do
      cp ${pkgs.fira-sans}/share/fonts/opentype/FiraSans-$f.otf \
        $out/share/fonts/opentype/
    done
  '';
in
{
  # gawk does all the parsing and all the drawing: it turns kubectl's
  # custom-columns output into the keys and groups, shuffles the plan (srand
  # is why the image pins one awk build and a host shell does not), and writes
  # the timeline SVG by hand.
  #
  # coreutils is here for `cut`, `sort`, `wc`, `tr`, `mktemp` and `sleep`. It is
  # no longer here for `date`: the timestamps the whole report is built on come
  # from bash's own $EPOCHREALTIME now, because forking a process to read a
  # clock puts the fork inside the interval being measured. `date` is still
  # called once, for the run directory's name.
  #
  # gnugrep and gnused are small and are what the script reaches for around the
  # edges; gnutar and gzip are absent deliberately, unlike in storage-bench — a
  # finished chaos run is a dozen files, not a few thousand, so there is
  # nothing to tar up.
  packages = [
    kubectl
    cmark-gfm
    typst
    fira-sans
  ] ++ (with pkgs; [
    bashInteractive
    coreutils
    gawk
    gnugrep
    gnused
  ]);

  # Where typst is told to find them. It is passed `--ignore-system-fonts`, so
  # it will not go looking on its own — which is the point, and is what makes
  # a host run and a container run set the same type. default.nix exports this
  # into the script's own environment and shell.nix into the host shell.
  fontPath = "${fira-sans}/share/fonts";
}
