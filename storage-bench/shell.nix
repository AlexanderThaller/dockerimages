# A host shell holding exactly what the container image holds, so a run on the
# host produces the same report as a run in the image:
#
#   nix-shell --run './storage-bench.sh /tank/backup'
#   nix-shell                                          # then run it by hand
#
# Without this, a host that has fio but no gnuplot still finishes the whole
# benchmark and then hands you a report with no graphs in it.
#
# The gnuplot here is the image's cut-down build, which draws SVG and has no
# rasterising terminals at all. That is deliberate: a host shell that could
# still produce PNGs would hide a difference the image cannot reproduce.

{ pkgs ? import (import ./nixpkgs.nix) { } }:

pkgs.mkShell {
  packages = (import ./runtime-deps.nix pkgs).packages;
}
