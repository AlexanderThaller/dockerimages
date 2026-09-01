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

pkgs.mkShell {
  packages = (import ./runtime-deps.nix pkgs).packages;
}
