#!/usr/bin/env bash
#
# stage-fixture.sh — create throwaway workloads in a namespace that look enough
#                    like a storage provider for storage-chaos.sh to be tried
#                    against them, on stage, without touching ODF or Portworx.
#
# Usage:
#   ./stage-fixture.sh up chaos-test
#   ./stage-fixture.sh status chaos-test
#   ./stage-fixture.sh down chaos-test
#
# This is not in the container image and is not meant to be: it exists to make
# a stage cluster safe to rehearse on, and shipping it beside the thing that
# deletes pods would put a pod *creator* into a container whose whole job is
# the opposite. Run it from a checkout, with a kubeconfig that can create
# workloads.
#
# What it creates, and why each one:
#
#   chaos-osd-0..N   one Deployment per replica, 1 pod each, the way Rook runs
#                    Ceph OSDs. Their pods are owned by a ReplicaSet whose name
#                    carries a hash, which is the case storage-chaos has to
#                    strip to keep a key stable across a rollout.
#   chaos-plugin     a DaemonSet, the way a CSI node plugin or the Portworx
#                    daemon runs. One pod per node, names that change on every
#                    restart, and the key that has to be node-scoped.
#   chaos-mon        a StatefulSet of 3, the way Ceph mons are quorate. Stable
#                    pod names, an ordinal, and a group where MIN_READY=1 is
#                    the difference between a rehearsal and an outage.
#
# Between them that is every owner kind storage-chaos builds a key from, which
# is the point: a run against this namespace exercises the same code paths a
# run against openshift-storage will, and gets them wrong somewhere harmless.
#
# The pods do nothing but sleep, and become ready READY_AFTER seconds after
# they start. That delay is the whole reason this is more useful than `oc run`:
# it gives every kill a recovery time that is known in advance, so the timeline
# in the report can be checked against a number rather than believed. Set it to
# 30 and every bar on the timeline should be a little over 30 seconds long.
#
# Tunables (env vars):
#   OSDS         chaos-osd Deployments to create   (default 3)
#   MONS         chaos-mon StatefulSet replicas    (default 3)
#   PLUGIN       1|0, create the DaemonSet         (default 1)
#   READY_AFTER  the floor: seconds before ready     (default 20)
#   READY_SPREAD uniform seconds on top of it        (default 20)
#   READY_TAIL   extra seconds for the slow ones     (default 45)
#   READY_TAIL_PCT  percent that get the tail        (default 12)
#   READY_STAGGER   seconds added per workload       (default 5)
#   TERM_AFTER   seconds before a killed pod exits   (default 0)
#   TERM_SPREAD  uniform seconds on top of it        (default 0)
#   IMAGE        image the pods run                (default ubi9/ubi-minimal)
#   CPU / MEMORY resource requests per pod         (default 10m / 32Mi)
#   RUN_AS_USER  uid the pods run as               (default: let the SCC pick)
#   KUBECTL      client to use, may carry flags    (default kubectl)
#
# TERM_AFTER/TERM_SPREAD govern a *graceful* kill (KILL_MODE=graceful) and
# plain deletes (`down`, a rollout): the pod's own command traps SIGTERM and
# exits on its own after that delay, rather than the default of every
# container ignoring SIGTERM as PID 1 and forcing the kubelet to wait out the
# full terminationGracePeriodSeconds — 30s by default — before it gives up and
# sends SIGKILL. force kills (the default KILL_MODE) go through the API
# directly and never touch this at all.
#
# The default image is Red Hat's ubi-minimal because it is what an OpenShift
# cluster can already pull — no Docker Hub rate limit, no pull secret — and
# because all that is needed of it is a shell and sleep. Anything with those
# works: IMAGE=busybox:latest is fine on a cluster that can reach Docker Hub.
#
# Everything is created with the securityContext that OpenShift's restricted-v2
# SCC requires, so it applies as an ordinary user rather than needing an SCC
# binding. The pods request 10 millicores and no storage at all.

set -uo pipefail
export LC_ALL=C

usage() {
  cat >&2 <<'USAGE'
Usage: stage-fixture.sh <up|down|status> <namespace>

  ./stage-fixture.sh up chaos-test          create the fixture workloads
  ./stage-fixture.sh status chaos-test      what is running, as chaos sees it
  ./stage-fixture.sh down chaos-test        delete them again

  OSDS=5 MONS=3 READY_AFTER=45 ./stage-fixture.sh up chaos-test

Then, from this checkout:

  MODE=deterministic ITERATIONS=6 INTERVAL=30 ./storage-chaos.sh chaos-test

Every recovery on the timeline should come out a little over READY_AFTER
seconds. If they do, the same run against openshift-storage is measuring what
it says it is.
USAGE
}

# Argument parsing, defaults and validation. A function for the same reason
# storage-chaos.sh has one: nothing here runs until main() at the bottom, so
# bash has read the whole file before any of it starts. `up` polls the API for
# up to fifteen seconds waiting for the namespace's uid range, and a file
# rewritten under a running bash resumes at an offset that now points into the
# middle of something else.
init_config() {
  ACTION="${1:-}"
  NS="${2:-}"
  [ -n "$ACTION" ] && [ -n "$NS" ] || {
    usage
    exit 1
  }

  OSDS="${OSDS:-3}"
  MONS="${MONS:-3}"
  PLUGIN="${PLUGIN:-1}"
  READY_AFTER="${READY_AFTER:-20}"

# The shape of the recovery-time distribution the fixture produces. With
# READY_SPREAD=0 every pod takes exactly READY_AFTER, which is what this did
# before and which draws a histogram with one bar in it — fine for checking the
# plumbing, useless for checking whether the charts say anything.
#
# A pod's delay is READY_AFTER plus a uniform draw up to READY_SPREAD, and one
# in READY_TAIL_PCT of them gets READY_TAIL on top. The tail is the point:
# storage recovers quickly most of the time and occasionally does not, and a
# symmetric spread hides exactly the case a chaos run is looking for.
READY_SPREAD="${READY_SPREAD:-20}"
READY_TAIL="${READY_TAIL:-45}"
READY_TAIL_PCT="${READY_TAIL_PCT:-12}"

# Seconds added per workload, in creation order, so the components differ from
# each other and not only within themselves — which is what makes the report's
# per-component histogram facets worth looking at. 0 gives every workload the
# same base.
READY_STAGGER="${READY_STAGGER:-5}"

  # How long a graceful kill takes to actually exit — see the header comment.
  # 0/0 by default: instant, so `down` and a KILL_MODE=graceful run are not
  # slowed down by this fixture unless asked for.
  TERM_AFTER="${TERM_AFTER:-0}"
  TERM_SPREAD="${TERM_SPREAD:-0}"

  IMAGE="${IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}"
  CPU="${CPU:-10m}"
  MEMORY="${MEMORY:-32Mi}"

  # Left unset, the uid is worked out from the namespace itself — see
  # resolve_uid. Set it to pin one.
  RUN_AS_USER="${RUN_AS_USER:-}"

  read -r -a KUBECTL <<<"${KUBECTL:-kubectl}"
  kc() { "${KUBECTL[@]}" "$@"; }

  for v in OSDS MONS READY_AFTER READY_SPREAD READY_TAIL READY_TAIL_PCT READY_STAGGER \
    TERM_AFTER TERM_SPREAD; do
    case "${!v}" in
    '' | *[!0-9]*)
      echo "$v must be a non-negative integer (got '${!v}')" >&2
      exit 1
      ;;
    esac
  done

  # terminationGracePeriodSeconds has to cover the worst case of the trap's
  # own delay, or the kubelet's SIGKILL races the pod's graceful exit and
  # always wins — which would make TERM_AFTER/TERM_SPREAD a lie. +2s of slack
  # for the shell itself to notice the signal and run the trap.
  TERM_GRACE=$((TERM_AFTER + TERM_SPREAD + 2))
}

# The uid the pods run as, which has to be a real number in the manifest rather
# than left to the cluster.
#
# `runAsNonRoot: true` with no `runAsUser` is a promise the *kubelet* checks,
# against the image's own USER — and ubi-minimal's is root, so the pod dies at
# start with "container has runAsNonRoot and image will run as root". On
# OpenShift that is normally invisible, because the restricted-v2 SCC fills
# `runAsUser` in from the namespace's allocated range during admission and the
# kubelet then has a number to check. It does not always: a ServiceAccount
# bound to an SCC with RunAsAny — `anyuid`, `privileged` — is admitted by that
# one instead, which injects nothing, and the promise is left unbacked.
#
# So the range is read off the namespace and its first uid used. That is the
# same number restricted-v2 would have chosen, so the pods are admitted by it
# unchanged; it is inside the range, so an explicit uid cannot be rejected as
# out of it; and on a cluster with no SCCs at all there is no annotation and
# 1000 is as good a uid as any.
#
# The annotation is written by a controller shortly after the namespace is
# created, not by the create itself, so a fixture going up in a brand new
# namespace has to wait a moment for it.
resolve_uid() {
  [ -n "$RUN_AS_USER" ] && {
    printf '%s' "$RUN_AS_USER"
    return
  }
  local range i=0
  while [ "$i" -lt 15 ]; do
    range="$(kc get namespace "$NS" \
      -o 'jsonpath={.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' 2>/dev/null)"
    [ -n "$range" ] && {
      printf '%s' "${range%%/*}"
      return
    }
    i=$((i + 1))
    sleep 1
  done
  printf '1000'
}

# The pod spec every workload below shares. Ready READY_AFTER seconds after the
# container starts and not before: the probe looks for a file the command only
# touches once it has slept, which is a readiness gate that costs nothing and
# is exact.
#
# The probe's own period is 1s so that the file appearing and the pod going
# Ready are not several seconds apart — the delay being measured is meant to be
# READY_AFTER, not READY_AFTER plus a probe interval.
pod_spec() { # <indent> <base delay seconds>
  local i="$1" base="$2"
  sed "s/^/$i/" <<SPECEOF
securityContext:
  runAsNonRoot: true
  runAsUser: $POD_UID
  seccompProfile:
    type: RuntimeDefault
terminationGracePeriodSeconds: $TERM_GRACE
containers:
  - name: sleeper
    image: $IMAGE
    command:
      - /bin/sh
      - -c
      - |
        # A different delay on every start, so a run against this fixture
        # produces a distribution rather than one spike. Entropy comes from the
        # clock, in POSIX shell arithmetic, with no awk, od or /dev/urandom
        # needed in the image.
        #
        # Nanoseconds where date has them, which is the default image. Busybox
        # prints a literal "%N" and some builds return all zeros, so both are
        # caught and fall back to epoch seconds — coarser, because two pods
        # restarting inside the same second then draw the same delay, but pods
        # restarting seconds apart still differ. The leading zeros are stripped
        # because shell arithmetic reads a leading zero as octal, and 048 is
        # not a number at all.
        n=\$(date +%N 2>/dev/null)
        case "\$n" in '' | *[!0-9]*) n= ;; esac
        n=\${n#\${n%%[!0]*}}
        [ -n "\$n" ] || n=\$(date +%s)
        d=\$(( $base + n % ($READY_SPREAD + 1) ))
        # The long tail. Real storage recovers quickly most of the time and
        # occasionally does not, and a symmetric spread hides exactly the case
        # a chaos run is looking for. A different slice of the same number
        # decides, so the two draws do not move together.
        tail=0
        if [ \$(( (n / 100000) % 100 )) -lt $READY_TAIL_PCT ]; then
          d=\$(( d + $READY_TAIL ))
          tail=1
        fi
        # Printed before the sleep, not after, so a log tail shows the target
        # the moment the container starts rather than only confirming it in
        # hindsight once the probe has already caught it.
        echo "\$HOSTNAME: recovering in \${d}s (base=${base}s spread=${READY_SPREAD}s tail=\$tail)"
        sleep \$d
        touch /tmp/ready
        echo "\$HOSTNAME: ready after \${d}s"
        # PID 1 in a container ignores any signal it has not explicitly
        # trapped — SIGTERM included — so execing into a bare sleep here
        # would mean a graceful kill or a plain delete never actually exits
        # on its own: the kubelet waits out the full
        # terminationGracePeriodSeconds every single time and then sends
        # SIGKILL. Trapping it, and staying as the shell rather than execing
        # into sleep, means the pod exits on its own after
        # TERM_AFTER/TERM_SPREAD instead.
        #
        # The wait has to be backgrounded: a trap only runs between commands,
        # so a foreground sleep would still block it until that sleep itself
        # returned, which is never.
        term() {
          tn=\$(date +%N 2>/dev/null)
          case "\$tn" in '' | *[!0-9]*) tn= ;; esac
          tn=\${tn#\${tn%%[!0]*}}
          [ -n "\$tn" ] || tn=\$(date +%s)
          td=\$(( $TERM_AFTER + tn % ($TERM_SPREAD + 1) ))
          echo "\$HOSTNAME: terminating in \${td}s"
          sleep "\$td"
          exit 0
        }
        trap term TERM
        while true; do
          sleep 3600 &
          wait \$!
        done
    readinessProbe:
      exec:
        command: ["/bin/sh", "-c", "test -f /tmp/ready"]
      periodSeconds: 1
      initialDelaySeconds: 1
      failureThreshold: 1
    resources:
      requests:
        cpu: "$CPU"
        memory: "$MEMORY"
      limits:
        memory: "$MEMORY"
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    volumeMounts:
      - name: scratch
        mountPath: /tmp
volumes:
  - name: scratch
    emptyDir: {}
SPECEOF
}

manifests() {
  local i
  for ((i = 0; i < OSDS; i++)); do
    cat <<YAMLEOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chaos-osd-$i
  namespace: $NS
  labels: { app: chaos-osd, chaos-fixture: "true", osd-id: "$i" }
spec:
  replicas: 1
  selector:
    matchLabels: { app: chaos-osd, osd-id: "$i" }
  template:
    metadata:
      labels: { app: chaos-osd, chaos-fixture: "true", osd-id: "$i" }
    spec:
$(pod_spec "      " "$((READY_AFTER + i * READY_STAGGER))")
YAMLEOF
  done

  if [ "$PLUGIN" -eq 1 ]; then
    cat <<YAMLEOF
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: chaos-plugin
  namespace: $NS
  labels: { app: chaos-plugin, chaos-fixture: "true" }
spec:
  selector:
    matchLabels: { app: chaos-plugin }
  template:
    metadata:
      labels: { app: chaos-plugin, chaos-fixture: "true" }
    spec:
$(pod_spec "      " "$((READY_AFTER + OSDS * READY_STAGGER))")
YAMLEOF
  fi

  if [ "$MONS" -gt 0 ]; then
    # No volumeClaimTemplates: a StatefulSet is here for its stable pod names
    # and its ordinals, which is what storage-chaos keys on, and a PVC per
    # replica would leave storage behind on a stage cluster after `down`.
    cat <<YAMLEOF
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: chaos-mon
  namespace: $NS
  labels: { app: chaos-mon, chaos-fixture: "true" }
spec:
  serviceName: chaos-mon
  replicas: $MONS
  podManagementPolicy: Parallel
  selector:
    matchLabels: { app: chaos-mon }
  template:
    metadata:
      labels: { app: chaos-mon, chaos-fixture: "true" }
    spec:
$(pod_spec "      " "$((READY_AFTER + (OSDS + 1) * READY_STAGGER))")
YAMLEOF
  fi
}

run_action() {
  case "$ACTION" in
  up)
    kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null || exit 1
    POD_UID="$(resolve_uid)"
    manifests | kc apply -f - || exit 1
    echo
    echo "Fixture up in $NS: $OSDS osd deployments, $MONS mons$([ "$PLUGIN" -eq 1 ] && echo ", one plugin daemonset"), running as uid $POD_UID."
    echo "Pods go ready between ${READY_AFTER}s and $((READY_AFTER + (OSDS + 1) * READY_STAGGER + READY_SPREAD))s after they start,"
    echo "and ${READY_TAIL_PCT}% of them take ${READY_TAIL}s longer still — so that is the spread the"
    echo "recovery histogram from this fixture should show. READY_SPREAD=0"
    echo "restores a single fixed delay."
    echo "A graceful kill or delete exits between ${TERM_AFTER}s and $((TERM_AFTER + TERM_SPREAD))s later —"
    echo "force kills (the default) go through the API directly and skip this entirely."
    echo
    echo "  ./storage-chaos.sh $NS"
    echo "  INCLUDE='/chaos-osd-' ./storage-chaos.sh $NS      # the OSD lookalikes alone"
    echo "  ./stage-fixture.sh down $NS"
    ;;

  down)
    # By label rather than by name, so a fixture created with OSDS=9 is fully
    # removed by a `down` run without it — deleting what was asked for this time
    # would leave the rest of it running on a stage cluster indefinitely.
    kc delete deployment,daemonset,statefulset -n "$NS" -l chaos-fixture=true --wait=false
    echo "Fixture removed from $NS. The namespace itself was left alone."
    ;;

  status)
    # The same columns storage-chaos builds its keys and groups from, so what is
    # printed here is what a run would see.
    kc get pods -n "$NS" -l chaos-fixture=true \
      -o 'custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,OWNER_KIND:.metadata.ownerReferences[0].kind,OWNER:.metadata.ownerReferences[0].name,PHASE:.status.phase,READY:.status.conditions[?(@.type=="Ready")].status'
    ;;

  *)
    echo "unknown action '$ACTION'" >&2
    usage
    exit 1
    ;;
  esac
}

main() {
  init_config "$@"
  run_action
}

main "$@"
