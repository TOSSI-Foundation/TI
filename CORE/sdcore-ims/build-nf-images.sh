#!/usr/bin/env bash
#
# build-nf-images.sh - build the IMS-enabled SD-Core network function images.
#
# Clones the SMF, PCF and AMF at the setu-ims-rel1 branch and SETU at main,
# builds a container image for each, and (optionally) verifies, pushes, or
# loads them into the containerd your Kubernetes uses. You do not need to
# clone or check out anything yourself.
#
# Only git and docker are required. If Go is not installed, the vendoring step
# the upstream Makefile performs is transparently run inside a golang container,
# so the upstream build path is still the one that executes.
#
#   ./build-nf-images.sh                                  # build all four
#   ./build-nf-images.sh --verify                         # build + prove the IMS changes are in the binaries
#   ./build-nf-images.sh -r ghcr.io/acme/ --push          # build and publish
#   ./build-nf-images.sh --load-containerd                # build and import into k3s/rke2
#   ./build-nf-images.sh --nf setu                        # just the bridge
#
set -euo pipefail

ORG_URL="https://github.com/TOSSI-Foundation"
BRANCH="setu-ims-rel1"
GO_IMAGE="golang:1.25"
ALL_NFS="smf pcf amf setu"
SETU_URL="https://github.com/coranlabs/SETU.git"
SETU_BRANCH="main"

TAG="setu-ims-rel1"
REGISTRY=""
NFS="$ALL_NFS"
WORKDIR="$(pwd)/.nf-build"
JOBS=1
DO_PUSH=0
DO_VERIFY=0
DO_LOAD=0
DO_CLEAN=0
DRY=0

# Symbols that only exist because of the IMS work. --verify greps the built
# binary for these, which is the difference between "an image built" and "the
# right image built".
markers_for() {
  case "$1" in
    smf) echo "SmPolicyUpdateNotificationBare buildGBRQosInformation canonicalFlowKey" ;;
    pcf) echo "PCFDBG-SelfHeal PCFDBG-BIND PCFDBG-ToSMF" ;;
    amf) echo "EventChannel).Start.func" ;;
    setu) echo "npcf-policyauthorization Digest-AKAv1-MD5 vnd.3gpp.sms" ;;
  esac
}

# SETU lives in a different org, tracks main, and ships as "setu" rather than
# "5gc-<nf>". Everything else about it is the same shape.
repo_url()  { case "$1" in setu) echo "$SETU_URL" ;; *) echo "$ORG_URL/sdcore-$1.git" ;; esac; }
repo_ref()  { case "$1" in setu) echo "$SETU_BRANCH" ;; *) echo "$BRANCH" ;; esac; }
src_dir()   { case "$1" in setu) echo "$WORKDIR/SETU" ;; *) echo "$WORKDIR/sdcore-$1" ;; esac; }
image_of()  { case "$1" in setu) echo "${REGISTRY}setu:${TAG}" ;; *) echo "${REGISTRY}5gc-$1:${TAG}" ;; esac; }

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
[ -t 1 ] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; }
say()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '  %s✓%s %s\n'  "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n'  "$C_Y" "$C_0" "$*"; }
die()  { printf '%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }

usage() {
  # print only the leading comment block, however long it happens to be
  sed -n '2,40p' "$0" | sed -n '/^#/p' | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  -t, --tag TAG           image tag                       (default: $TAG)
  -r, --registry PREFIX   registry prefix, trailing slash added if missing
                          e.g. ghcr.io/acme/  ->  ghcr.io/acme/5gc-smf:$TAG
  -n, --nf LIST           comma-separated: smf,pcf,amf     (default: all)
  -w, --workdir DIR       where sources are cloned         (default: ./.nf-build)
  -j, --jobs N            build N images in parallel       (default: 1)
      --verify            extract each binary and confirm the IMS symbols are present
      --push              docker push after a successful build
      --load-containerd   import into the k3s/rke2 containerd namespace (needs sudo)
      --clean             delete the workdir before starting
      --dry-run           print the steps without doing them
  -h, --help              this message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--tag)            TAG="${2:?}"; shift 2 ;;
    -r|--registry)       REGISTRY="${2:?}"; shift 2 ;;
    -n|--nf)             NFS="$(echo "${2:?}" | tr ',' ' ')"; shift 2 ;;
    -w|--workdir)        WORKDIR="${2:?}"; shift 2 ;;
    -j|--jobs)           JOBS="${2:?}"; shift 2 ;;
    --verify)            DO_VERIFY=1; shift ;;
    --push)              DO_PUSH=1; shift ;;
    --load-containerd)   DO_LOAD=1; shift ;;
    --clean)             DO_CLEAN=1; shift ;;
    --dry-run)           DRY=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) die "unknown option: $1  (try --help)" ;;
  esac
done

case "$REGISTRY" in ""|*/) ;; *) REGISTRY="$REGISTRY/" ;; esac
for nf in $NFS; do
  case " $ALL_NFS " in *" $nf "*) ;; *) die "unknown network function: $nf" ;; esac
done

# ---------------------------------------------------------------- preflight --
preflight() {
  say "Checking what this machine has"
  command -v git    >/dev/null 2>&1 || die "git is required"
  command -v docker >/dev/null 2>&1 || die "docker is required (or podman aliased to docker)"
  if [ "$DRY" = 0 ]; then
    docker info >/dev/null 2>&1 || die "the docker daemon is not reachable - is it running, and are you in the docker group?"
  fi
  ok "git    $(git --version | awk '{print $3}')"
  local dver=""
  dver=$(docker version --format '{{.Server.Version}}' 2>/dev/null | head -1) || dver=""
  ok "docker ${dver:-present}"

  if command -v go >/dev/null 2>&1; then
    GO_MODE="host"
    ok "go     $(go version | awk '{print $3}') - using it directly"
  else
    GO_MODE="container"
    warn "go is not installed - vendoring will run inside $GO_IMAGE instead"
  fi

  local free
  free=$(df -Pm "$(dirname "$WORKDIR")" 2>/dev/null | awk 'NR==2{print $4}')
  [ -n "${free:-}" ] && [ "$free" -lt 6000 ] 2>/dev/null \
    && warn "only ${free}MB free here - a full three-NF build wants roughly 6GB"
  return 0
}

# The upstream Makefile runs "go mod vendor" on the host during docker-build.
# When the host has no Go we put a shim on PATH that proxies the call into a
# container, so the upstream build path runs unchanged rather than being
# reimplemented here (which would drift the moment upstream changes).
setup_go_shim() {
  [ "$GO_MODE" = "container" ] || return 0
  SHIM_DIR="$WORKDIR/.shim"
  mkdir -p "$SHIM_DIR" "$WORKDIR/.gocache"
  cat > "$SHIM_DIR/go" <<SHIM
#!/bin/sh
exec docker run --rm \\
  -u "\$(id -u):\$(id -g)" \\
  -v "\$PWD":/src -w /src \\
  -v "$WORKDIR/.gocache":/gocache \\
  -e GOPATH=/gocache/gopath -e GOCACHE=/gocache/build -e GOFLAGS=-mod=mod -e HOME=/tmp \\
  $GO_IMAGE go "\$@"
SHIM
  chmod +x "$SHIM_DIR/go"
  PATH="$SHIM_DIR:$PATH"; export PATH
  ok "go shim installed - 'go' now runs in $GO_IMAGE"
}

# ------------------------------------------------------------------- source --
fetch_one() {
  local nf="$1" dir ref url
  dir=$(src_dir "$nf"); ref=$(repo_ref "$nf"); url=$(repo_url "$nf")
  if [ -d "$dir/.git" ]; then
    run git -C "$dir" fetch --quiet origin "$ref"
    run git -C "$dir" checkout --quiet "$ref"
    run git -C "$dir" reset --hard --quiet "origin/$ref"
  else
    run git clone --quiet --branch "$ref" "$url" "$dir"
  fi
  [ "$DRY" = 1 ] && return 0
  run git -C "$dir" clean -fdq
  local on; on=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
  [ "$on" = "$ref" ] || die "$nf is on '$on', expected '$ref'"
  ok "$(basename "$dir") @ $ref ($(git -C "$dir" rev-parse --short HEAD))"
}

# -------------------------------------------------------------------- build --
build_one() {
  local nf="$1" dir log img
  dir=$(src_dir "$nf"); img=$(image_of "$nf"); log="$WORKDIR/$nf-build.log"
  if [ "$DRY" = 1 ]; then
    printf '  would build %s from %s\n' "$img" "$dir"; return 0
  fi
  local rc=0
  if [ "$nf" = setu ]; then
    # SETU compiles inside its own Dockerfile - no host Go, no vendoring step.
    ( cd "$dir" && docker build -f deploy/Dockerfile.build -t "$img" . ) >"$log" 2>&1 || rc=$?
  else
    make -C "$dir" docker-build \
      DOCKER_REGISTRY="$REGISTRY" DOCKER_TAG="$TAG" >"$log" 2>&1 || rc=$?
  fi
  if [ "$rc" = 0 ]; then ok "built $img"; return 0; fi
  printf '%serror:%s %s failed to build - last 20 lines of %s\n' "$C_R" "$C_0" "$nf" "$log" >&2
  tail -20 "$log" | sed 's/^/      /' >&2
  return 1
}

# Pull the binary out of the image and look for symbols that exist only because
# of the IMS work. Uses docker create/cp so it works even on images with no shell.
verify_one() {
  local nf="$1" img; img=$(image_of "$nf")
  local tmp cid missing=0
  tmp=$(mktemp -d); cid=$(docker create "$img" 2>/dev/null) || { warn "$nf: could not inspect image"; rm -rf "$tmp"; return 1; }
  docker cp "$cid:/usr/local/bin/$nf" "$tmp/$nf" >/dev/null 2>&1 || {
    warn "$nf: /usr/local/bin/$nf not found in the image"; docker rm -f "$cid" >/dev/null; rm -rf "$tmp"; return 1; }
  docker rm -f "$cid" >/dev/null
  for m in $(markers_for "$nf"); do
    if grep -qa -- "$m" "$tmp/$nf"; then printf '    %s✓%s %s\n' "$C_G" "$C_0" "$m"
    else printf '    %s✗%s %s  MISSING\n' "$C_R" "$C_0" "$m"; missing=1; fi
  done
  rm -rf "$tmp"
  [ "$missing" = 0 ] && ok "$nf: the IMS changes are in the binary" || warn "$nf: this image is missing IMS symbols - wrong branch?"
  return "$missing"
}

# ------------------------------------------------------------- distribution --
push_one() {
  local nf="$1" img; img=$(image_of "$nf")
  [ -n "$REGISTRY" ] || die "--push needs --registry (an image with no registry prefix has nowhere to go)"
  run docker push "$img"
  [ "$DRY" = 0 ] && ok "pushed $img"
  return 0
}

# Import straight into the containerd that k3s/rke2 uses, so a cluster on this
# same host can run the image without a registry at all.
load_one() {
  local nf="$1" sock="" img; img=$(image_of "$nf")
  for s in /run/k3s/containerd/containerd.sock /run/containerd/containerd.sock; do
    [ -S "$s" ] && { sock="$s"; break; }
  done
  [ -n "$sock" ] || { warn "no containerd socket found - skipping load for $nf"; return 0; }
  local ctr; ctr=$(command -v ctr || echo /var/lib/rancher/rke2/bin/ctr)
  [ -x "$ctr" ] || { warn "ctr not found - skipping load for $nf"; return 0; }
  if [ "$DRY" = 1 ]; then printf '  would import %s into %s\n' "$img" "$sock"; return 0; fi
  docker save "$img" | sudo "$ctr" --address "$sock" -n k8s.io images import - >/dev/null \
    && ok "imported $img into containerd" \
    || warn "could not import $nf - is sudo available?"
}

# --------------------------------------------------------------------- main --
main() {
  [ "$DO_CLEAN" = 1 ] && { say "Removing $WORKDIR"; rm -rf "$WORKDIR"; }
  mkdir -p "$WORKDIR"

  preflight
  setup_go_shim

  say "Fetching sources from $ORG_URL"
  for nf in $NFS; do fetch_one "$nf"; done

  say "Building images (tag: $TAG${REGISTRY:+, registry: $REGISTRY})"
  local failed=""
  if [ "$JOBS" -gt 1 ] && [ "$DRY" = 0 ]; then
    local pids="" nfl=""
    for nf in $NFS; do
      build_one "$nf" & pids="$pids $!"; nfl="$nfl $nf"
      while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || break; done
    done
    wait || true
    for nf in $NFS; do
      docker image inspect "$(image_of "$nf")" >/dev/null 2>&1 || failed="$failed $nf"
    done
  else
    for nf in $NFS; do build_one "$nf" || failed="$failed $nf"; done
  fi
  [ -n "$failed" ] && die "failed to build:$failed"

  if [ "$DO_VERIFY" = 1 ] && [ "$DRY" = 0 ]; then
    say "Verifying the IMS changes are actually in these binaries"
    local bad=""
    for nf in $NFS; do printf '  %s\n' "$(basename "$(src_dir "$nf")")"; verify_one "$nf" || bad="$bad $nf"; done
    [ -n "$bad" ] && die "verification failed for:$bad"
  fi

  [ "$DO_PUSH" = 1 ] && { say "Pushing"; for nf in $NFS; do push_one "$nf"; done; }
  [ "$DO_LOAD" = 1 ] && { say "Loading into containerd"; for nf in $NFS; do load_one "$nf"; done; }

  say "Done"
  if [ "$DRY" = 0 ]; then
    printf '\n  %-38s %-10s %s\n' "IMAGE" "SIZE" "BUILT"
    for nf in $NFS; do
      # docker's template engine has no arithmetic, so size is formatted here
      local bytes created
      local im; im=$(image_of "$nf")
      bytes=$(docker image inspect "$im" --format '{{.Size}}' 2>/dev/null) || continue
      created=$(docker image inspect "$im" --format '{{.Created}}' 2>/dev/null | cut -c1-19)
      printf '  %-38s %-10s %s\n' "$im" "$((bytes / 1048576))MB" "$created"
    done
    cat <<EOF

  Point your deployment at these images, for example:

    kubectl -n <namespace> set image deploy/smf smf=${REGISTRY}5gc-smf:${TAG}
    kubectl -n <namespace> set image deploy/pcf pcf=${REGISTRY}5gc-pcf:${TAG}
    kubectl -n <namespace> set image deploy/amf amf=${REGISTRY}5gc-amf:${TAG}

  SETU runs alongside, not in the cluster - see the guide for its configuration.

  Sources are in $WORKDIR if you want to read what was built.
EOF
  fi
}

main "$@"
