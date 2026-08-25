#!/usr/bin/env bash
# scripts/build.sh — build one image (and its ancestors), a named set, or all.
#
#   ./scripts/build.sh                  # every image, including quasar-unigine
#   ./scripts/build.sh quasar-kde       # quasar-kde and everything it needs
#   ./scripts/build.sh ci               # the set GitHub Actions builds
#   ./scripts/build.sh verify quasar-kde
#   ./scripts/build.sh check            # validate build-graph.json
#
# WHAT IS BUILT AND IN WHAT ORDER IS NOT IN THIS FILE. It is in
# build-graph.json, read through scripts/graph.sh. This script only knows how to
# turn one graph entry into a `docker build` invocation. See AGENTS.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

graph() { "$SCRIPT_DIR/graph.sh" "$@"; }

tag="${QUASAR_IMAGE_TAG:-dev}"

# ── The benchapp payload ──────────────────────────────────────────────────────
#
# images/quasar-benchapp/Dockerfile lifts its binary from another image. That
# image's source is github.com/accretion-io/quasar-mark, a SEPARATE (private)
# repo, so `build.sh all` on a clean runner had no way to produce it and failed
# on `FROM quasar-benchapp:src` -- which is why CI never built this image.
#
# Resolution order, most specific first:
#   1. $BENCHAPP_SRC_IMAGE            an explicit override, always wins
#   2. quasar-benchapp:src            a local build, if one is present. This is
#                                     the devbox loop: build it in a quasar-mark
#                                     checkout, then build here. Preserved
#                                     deliberately -- a devbox iterating on the
#                                     probe must not be forced through a publish.
#   3. the registry image quasar-mark publishes. The clean-runner path.
#
# See AGENTS.md, "The benchapp payload", for the GHCR package-read prerequisite
# on (3).
BENCHAPP_SRC_FALLBACK="${BENCHAPP_SRC_FALLBACK:-ghcr.io/accretion-io/quasar-benchapp-src:latest}"
resolve_benchapp_src() {
  [ -z "${BENCHAPP_SRC_IMAGE:-}" ] || return 0
  if docker image inspect quasar-benchapp:src >/dev/null 2>&1; then
    export BENCHAPP_SRC_IMAGE="quasar-benchapp:src"
  else
    export BENCHAPP_SRC_IMAGE="$BENCHAPP_SRC_FALLBACK"
  fi
  echo "build.sh: benchapp payload -> $BENCHAPP_SRC_IMAGE" >&2
}

build_one() {
  local image="$1" df target
  [ "$image" = quasar-benchapp ] && resolve_benchapp_src

  df="$(graph field "$image" dockerfile)"
  target="$(graph field "$image" target)"

  local flags=(-f "$df" -t "$image:$tag")
  [ -n "$target" ] && flags+=(--target "$target")

  local kv
  while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    flags+=(--build-arg "$kv")
  done < <(graph args "$image")

  DOCKER_BUILDKIT=1 docker build --progress=plain "${flags[@]}" .
}

build_set() {
  local image
  for image in "$@"; do
    echo "==> $image" >&2
    build_one "$image"
  done
}

verify_one() {
  local image="$1" script found=0
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    found=1
    echo "==> verify $image: $script" >&2
    QUASAR_IMAGE_TAG="$tag" "$REPO_ROOT/$script"
  done < <(graph verify "$image")
  [ "$found" = 1 ] || echo "build.sh: $image declares no verify script" >&2
}

usage() {
  {
    echo "usage: $0 [all|ci|check|verify <image>|<image>]"
    echo "images: $(graph names | tr '\n' ' ')"
  } >&2
  exit 64
}

case "${1:-all}" in
  check)  graph check ;;
  verify)
    [ $# -eq 2 ] || usage
    verify_one "$2"
    ;;
  # `all` is the LOCAL set: everything, quasar-unigine included. `ci` is what
  # GitHub Actions builds -- see build-graph.json for why unigine is not in it.
  all)    build_set $(graph set all) ;;
  ci)     build_set $(graph set ci) ;;
  *)
    graph names | grep -qxF "$1" || usage
    build_set $(graph order "$1")
    ;;
esac
