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
  # links for a package registry this image never reaches. `just size` is what
  # says whether that is still the number after a nixpkgs bump.
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
  ] ++ (with pkgs; [
    bashInteractive
    coreutils
    gawk
    gnugrep
    gnused
  ]);
}
