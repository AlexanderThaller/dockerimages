# storage-chaos — a container image that runs ./storage-chaos.sh, with kubectl,
# cmark-gfm, gawk and bash.
#
#   nix-build                       # -> ./result, a docker image tarball
#   docker load < result            # or: podman load < result
#
#   # storage-chaos.sh is the entrypoint; trailing args are the namespaces:
#   docker run --rm -v ~/.kube:/kube:ro -e KUBECONFIG=/kube/config \
#       -v "$PWD/chaos-results:/out" -e OUTBASE=/out \
#       storage-chaos:latest openshift-storage
#
#   # in cluster it needs no kubeconfig — see deploy/ for the Job and the RBAC:
#   oc apply -f deploy/rbac.yaml -f deploy/job.yaml
#
# The image contains nothing but the Nix closure of the tools below: no distro
# userland, no package manager, no shell profile scripts.
#
# Cross-building from a non-Linux host works by overriding pkgsLinux:
#   nix-build --arg pkgsLinux 'import (import ./nixpkgs.nix) { system = "x86_64-linux"; }'

{ pkgs ? import (import ./nixpkgs.nix) { }
, pkgsLinux ? pkgs
, name ? "storage-chaos"
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
  # the script's own $0 the hidden .storage-chaos-wrapped path, which then
  # shows up in its usage message.
  storage-chaos = pkgsLinux.runCommand "storage-chaos" { } ''
    install -Dm755 ${./storage-chaos.sh} $out/bin/storage-chaos
    substituteInPlace $out/bin/storage-chaos \
      --replace-fail '#!/usr/bin/env bash' '#!${pkgsLinux.bashInteractive}/bin/bash
    export PATH=${lib.makeBinPath runtimeDeps}''${PATH:+:$PATH}'
  '';
in

pkgs.dockerTools.buildLayeredImage {
  inherit name tag;

  contents = runtimeDeps ++ [
    storage-chaos

    # Bare essentials for a scratch-style image: /bin/sh, /usr/bin/env,
    # /etc/{passwd,group,nsswitch.conf} and the CA bundle under /etc/ssl.
    #
    # fakeNss earns its place twice over here. nsswitch.conf is what lets glibc
    # resolve kubernetes.default.svc through DNS at all — without it an
    # in-cluster run cannot find its own API server — and the CA bundle is what
    # a run against a public API endpoint verifies against. In cluster the API
    # server's CA comes from the mounted ServiceAccount instead, and kubectl
    # finds it by itself.
    pkgs.dockerTools.binSh
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.fakeNss
    pkgs.dockerTools.caCertificates
  ];

  # /out is where the run directory is expected to be mounted, and /tmp is
  # where it goes when nothing is. Both are 1777 because OpenShift runs this
  # under an arbitrary uid from the namespace's range, which is in no group the
  # image could have known about at build time.
  #
  # kubectl also wants a writable HOME for its discovery cache; the config
  # below points HOME at /tmp rather than the /root it cannot write.
  extraCommands = ''
    mkdir -p -m 1777 tmp out
  '';

  config = {
    # storage-chaos.sh is the entrypoint, so trailing arguments are appended to
    # it rather than replacing it: `run <image> openshift-storage portworx`.
    # A bare run prints the script's usage. kubectl is still reachable with
    # `run --entrypoint kubectl <image> ...` (or --entrypoint bash).
    Entrypoint = [ "/bin/storage-chaos" ];
    Cmd = [ ];
    WorkingDir = "/out";

    # A non-root uid in the image itself, which is what a `runAsNonRoot: true`
    # pod spec with no `runAsUser` is checked against.
    #
    # dockerTools leaves USER unset, which means root, and a Kubernetes node
    # then refuses the pod outright: "container has runAsNonRoot and image will
    # run as root". On OpenShift that is usually hidden, because the
    # restricted-v2 SCC fills a uid in from the namespace's range during
    # admission — but a ServiceAccount bound to an SCC with RunAsAny (anyuid,
    # privileged) is admitted by that one instead, which injects nothing, and
    # the pod dies at start.
    #
    # 1000 is arbitrary and is overridden by anything that cares: an SCC's
    # injected uid, a pod spec's runAsUser, or `docker run --user`. Nothing
    # here reads or writes a file it did not create, so no uid needs to match
    # anything on disk.
    User = "1000";
    Env = [
      "PATH=/bin:/usr/bin"
      "HOME=/tmp"
      "TMPDIR=/tmp"
      "LANG=C.UTF-8"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
    ];
    Labels = {
      "org.opencontainers.image.title" = "storage-chaos";
      "org.opencontainers.image.description" =
        "kills storage-provider pods on a schedule and reports a timeline of what went when";
    };
  };
}
