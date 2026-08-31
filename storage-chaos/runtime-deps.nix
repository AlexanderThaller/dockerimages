# The runtime closure storage-chaos.sh needs, shared by the container image
# (default.nix) and the host shell (shell.nix) so the two cannot drift apart.
#
# Drift is the reason this is its own file, the same reason it is one in
# storage-bench: a host run missing cmark-gfm still kills every pod it was
# going to and then hands back a report that was never rendered — the kind of
# difference you notice after the cluster has already been disturbed.

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
  # finished chaos run is five files, not a few thousand, so there is nothing
  # to tar up.
  packages = [
    kubectl
    cmark-gfm
  ] ++ (with pkgs; [
    bashInteractive
    coreutils
    gawk
    gnugrep
    gnused
  ]);
}
