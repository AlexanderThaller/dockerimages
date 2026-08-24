# storage-bench — a container image that runs ./storage-bench.sh, with fio,
# gnuplot, cmark-gfm and bash.
#
#   nix-build                       # -> ./result, a docker image tarball
#   docker load < result            # or: podman load < result
#
#   # storage-bench.sh is the entrypoint; trailing args are its mount points:
#   docker run --rm -v /mnt/ceph:/data/ceph -v /mnt/px:/data/portworx \
#       storage-bench:latest /data/ceph /data/px
#
#   # or drive the tools directly:
#   docker run --rm -it --entrypoint bash storage-bench:latest
#
# The image contains nothing but the Nix closure of the tools below: no distro
# userland, no package manager, no shell profile scripts.
#
# Cross-building from a non-Linux host works by overriding pkgsLinux:
#   nix-build --arg pkgsLinux 'import (import ./nixpkgs.nix) { system = "x86_64-linux"; }'

{ pkgs ? import (import ./nixpkgs.nix) { }
, pkgsLinux ? pkgs
, name ? "storage-bench"
, tag ? "latest"
}:

let
  inherit (pkgsLinux) lib;

  # Shared with shell.nix, which is what gives a host run the same tools the
  # image has. See runtime-deps.nix for what each one is for.
  runtimeDeps = (import ./runtime-deps.nix pkgsLinux).packages;

  # The script gets an absolute interpreter and an absolute PATH, so it behaves
  # identically no matter what PATH the caller (Kubernetes, docker run -e, ...)
  # sets. Patched in rather than applied with wrapProgram: a wrapper would make
  # the script's own $0 the hidden .storage-bench-wrapped path, which then shows
  # up in its usage message.
  storage-bench = pkgsLinux.runCommand "storage-bench" { } ''
    install -Dm755 ${./storage-bench.sh} $out/bin/storage-bench
    substituteInPlace $out/bin/storage-bench \
      --replace-fail '#!/usr/bin/env bash' '#!${pkgsLinux.bashInteractive}/bin/bash
    export PATH=${lib.makeBinPath runtimeDeps}''${PATH:+:$PATH}'
  '';
in

pkgs.dockerTools.buildLayeredImage {
  inherit name tag;

  contents = runtimeDeps ++ [
    storage-bench

    # Bare essentials for a scratch-style image: /bin/sh, /usr/bin/env,
    # /etc/{passwd,group,nsswitch.conf} and the CA bundle under /etc/ssl.
    pkgs.dockerTools.binSh
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.fakeNss
    pkgs.dockerTools.caCertificates
  ];

  # storage-bench.sh writes its results under $OUTDIR, /tmp by default, and
  # /data is where the volumes under test are expected to be mounted.
  extraCommands = ''
    mkdir -p -m 1777 tmp
    mkdir -p data
  '';

  config = {
    # storage-bench.sh is the entrypoint, so trailing arguments are appended to
    # it rather than replacing it: `run <image> /data/ceph /data/portworx`.
    # A bare run prints the script's usage. The other tools are still reachable
    # with `run --entrypoint fio <image> ...` (or --entrypoint bash).
    Entrypoint = [ "/bin/storage-bench" ];
    Cmd = [ ];
    WorkingDir = "/data";
    Env = [
      "PATH=/bin:/usr/bin"
      "HOME=/root"
      "TMPDIR=/tmp"
      "LANG=C.UTF-8"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
    ];
    Labels = {
      "org.opencontainers.image.title" = "storage-bench";
      "org.opencontainers.image.description" =
        "dd/fio storage benchmark suite with gnuplot graphs and Markdown/HTML reporting";
    };
  };
}
