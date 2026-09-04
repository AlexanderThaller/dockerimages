# A host shell holding exactly what the container image holds, so a run on the
# host produces the same report as a run in the image:
#
#   nix-shell --run './storage-bench.sh /tank/backup'
#   nix-shell                                          # then run it by hand
#
# Without this, a host that has fio but no cmark-gfm still finishes the whole
# benchmark and then hands you a report that stayed Markdown instead of HTML.
# The graphs themselves need nothing beyond awk, which this shell — like the
# image — always has.

{ pkgs ? import (import ./nixpkgs.nix) { } }:

let
  runtime = import ./runtime-deps.nix pkgs;
in

pkgs.mkShell {
  packages = runtime.packages;

  # typst is run with --ignore-system-fonts, so this is the only way it finds
  # Fira Sans. Without it a host run would quietly typeset the PDF in typst's
  # bundled serif and look nothing like the one the image produces.
  TYPST_FONT_PATHS = runtime.fontPath;
}
