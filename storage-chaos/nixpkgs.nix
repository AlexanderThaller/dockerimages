# Pinned Nixpkgs, so `nix-build` gives the same image on every machine.
#
# Move it with `just update-nixpkgs`, and see whether the branch has moved on
# without touching anything with `just check-nixpkgs`. By hand:
#   git ls-remote https://github.com/NixOS/nixpkgs refs/heads/nixos-26.05
#   nix-prefetch-url --unpack https://github.com/NixOS/nixpkgs/archive/<rev>.tar.gz
let
  rev = "5dfba6236110080a54247d6460bc2ff5dda939cc"; # nixos-26.05, 2026-08-31
  sha256 = "04x9haniyhr419b1zprm1bsrb4z7yxrnqyxk0jpzp66acp351vbf";
in
builtins.fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
  inherit sha256;
}
