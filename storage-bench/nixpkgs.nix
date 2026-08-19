# Pinned Nixpkgs, so `nix-build` gives the same image on every machine.
#
# Refresh with:
#   git ls-remote https://github.com/NixOS/nixpkgs refs/heads/nixos-26.05
#   nix-prefetch-url --unpack https://github.com/NixOS/nixpkgs/archive/<rev>.tar.gz
let
  rev = "b18a4b905f8d028dc4476412e6d6891728695379"; # nixos-26.05, 2026-08-19
  sha256 = "10v8j96rh6fgzbxkyijkc071k3fkv6q9apx57p3kib7zaxqcy2l3";
in
builtins.fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
  inherit sha256;
}
