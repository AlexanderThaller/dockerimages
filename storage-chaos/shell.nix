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
