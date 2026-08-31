# A host shell holding exactly what the container image holds, so a run from a
# laptop against a cluster produces the same report as a run inside it:
#
#   nix-shell --run './storage-chaos.sh openshift-storage'
#   nix-shell                                              # then run it by hand
#
# Without this, a host that has kubectl but no cmark-gfm still kills every pod
# it was going to and then leaves the report as Markdown source.
#
# It also pins the awk, which is what makes MODE=random reproducible: the
# shuffle is seeded through awk's srand(), and the stream that follows a given
# seed is a property of the awk build.

{ pkgs ? import (import ./nixpkgs.nix) { } }:

pkgs.mkShell {
  packages = (import ./runtime-deps.nix pkgs).packages;
}
