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
#
# ── Layer cache (off by default) ──────────────────────────────────────────────
#
# With no QUASAR_CACHE_* set this runs exactly the `DOCKER_BUILDKIT=1 docker
# build` it always did: same driver, same local image store, no network. That is
# the devbox default on purpose -- a devbox already has a warm local layer cache
# and gains nothing from an external one. CI is the opposite case: every runner
# is cold, which is the whole reason this exists.
#
#   QUASAR_CACHE_REGISTRY=ghcr.io/accreleus   <image>:buildcache refs
#   QUASAR_CACHE_DIR=/path                       a local cache directory
#   QUASAR_CACHE_WRITE=1                         EXPORT as well as import
#   QUASAR_IMAGE_REGISTRY=ghcr.io/accreleus   see "the parent problem" below
#   QUASAR_BUILDER=quasar-images                 buildx builder name
#
# IMPORT is cheap and works on the ordinary `docker` driver, so cache-read alone
# changes nothing else. That is the pull-request path: read the cache the last
# reviewed push wrote, write nothing.
#
# EXPORT (mode=max) is the valuable half -- it is what puts INTERMEDIATE stage
# layers in the cache, and every expensive layer here (the Steam 32-bit closure,
# the bwrap and gamescope source builds, the kwin rpmbuild) lives in a stage that
# a mode=min/inline cache would not export at all. `--cache-to type=registry` is
# not supported by the `docker` driver, so exporting means a docker-container
# builder.
#
# THE PARENT PROBLEM, and it is the reason PR #25's version could not have
# worked. A docker-container builder cannot resolve a `FROM` against the local
# docker image store. `FROM quasar-base:dev` inside it fails with
#
#   ERROR: failed to solve: quasar-base:dev: failed to resolve source metadata
#   for docker.io/library/quasar-base:dev: pull access denied
#
# no matter how recently `--load` put that image in the store -- reproduced on
# the devbox, 2026-08-26. Every image in this repo except quasar-base builds
# `FROM` a sibling, so a container builder needs those siblings to be
# REGISTRY-resolvable. QUASAR_IMAGE_REGISTRY is that: with it set, each image is
# loaded locally (so the verify scripts still work) AND pushed to
# <registry>/<image>:<tag>, and graph.sh resolves every `@tag:` parent to the
# same ref. Export therefore REQUIRES it, and build.sh refuses the combination
# without it rather than failing four minutes later inside BuildKit.
#
# `--load` is not optional either: the container driver does not populate the
# local image store, so without it the build would pass and `./scripts/verify.sh`
# would then fail on `docker image inspect quasar-base:dev`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

graph() { "$SCRIPT_DIR/graph.sh" "$@"; }

tag="${QUASAR_IMAGE_TAG:-dev}"
builder="${QUASAR_BUILDER:-quasar-images}"
registry="${QUASAR_IMAGE_REGISTRY:-}"

cache_read()  { [ -n "${QUASAR_CACHE_REGISTRY:-}${QUASAR_CACHE_DIR:-}" ]; }
cache_write() { cache_read && [ "${QUASAR_CACHE_WRITE:-0}" = 1 ]; }
# Only cache EXPORT forces the container builder; import works on the plain
# driver, which keeps the cheap path free of the parent problem entirely.
use_buildx()  { cache_write || [ "${QUASAR_BUILDX:-0}" = 1 ]; }

if cache_write && [ -z "$registry" ]; then
  echo "build.sh: QUASAR_CACHE_WRITE needs QUASAR_IMAGE_REGISTRY -- a container" >&2
  echo "          builder cannot resolve 'FROM <local tag>'. See the header." >&2
  exit 78
fi

ensure_builder() {
  if docker buildx inspect "$builder" >/dev/null 2>&1; then return 0; fi
  echo "build.sh: creating docker-container buildx builder '$builder'" >&2
  docker buildx create --name "$builder" --driver docker-container --bootstrap >/dev/null
}

# Cache refs are PER IMAGE, not one shared ref. With a single shared ref each
# image's export overwrites the previous image's manifest, leaving only the last
# image built with a usable cache -- caching that looks wired up and does
# nothing.
cache_flags() {
  local image="$1"
  if [ -n "${QUASAR_CACHE_REGISTRY:-}" ]; then
    printf -- '--cache-from\ntype=registry,ref=%s/%s:buildcache\n' "$QUASAR_CACHE_REGISTRY" "$image"
    if [ "${QUASAR_CACHE_WRITE:-0}" = 1 ]; then
      printf -- '--cache-to\ntype=registry,ref=%s/%s:buildcache,mode=max\n' "$QUASAR_CACHE_REGISTRY" "$image"
    fi
  fi
  if [ -n "${QUASAR_CACHE_DIR:-}" ]; then
    # Importing a cache directory that does not exist yet is a hard BuildKit
    # error, not a miss -- so the first ever run must not pass --cache-from.
    if [ -d "$QUASAR_CACHE_DIR/$image" ]; then
      printf -- '--cache-from\ntype=local,src=%s/%s\n' "$QUASAR_CACHE_DIR" "$image"
    fi
    if [ "${QUASAR_CACHE_WRITE:-0}" = 1 ]; then
      mkdir -p "$QUASAR_CACHE_DIR/$image"
      printf -- '--cache-to\ntype=local,dest=%s/%s,mode=max\n' "$QUASAR_CACHE_DIR" "$image"
    fi
  fi
  return 0
}

# Publish the just-built image under its registry ref so the NEXT image in the
# chain can `FROM` it from inside the container builder. Cheap against a
# registry that already holds the layers; the publish workflow pushes the same
# content again under its release tags, and both are manifest-level work.
push_parent_ref() {
  local image="$1"
  docker tag "$image:$tag" "$registry/$image:$tag"
  docker push -q "$registry/$image:$tag" >/dev/null
  echo "build.sh: pushed parent ref $registry/$image:$tag" >&2
}

# ── The benchapp payload ──────────────────────────────────────────────────────
#
# images/quasar-benchapp/Dockerfile lifts its binary from another image. That
# image's source is github.com/accreleus/quasar-mark, a SEPARATE (private)
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
BENCHAPP_SRC_FALLBACK="${BENCHAPP_SRC_FALLBACK:-ghcr.io/accreleus/quasar-benchapp-src:latest}"
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
  if [ "$image" = quasar-benchapp ]; then resolve_benchapp_src; fi

  df="$(graph field "$image" dockerfile)"
  target="$(graph field "$image" target)"

  local flags=(-f "$df" -t "$image:$tag")
  if [ -n "$target" ]; then flags+=(--target "$target"); fi

  local kv
  while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    flags+=(--build-arg "$kv")
  done < <(graph args "$image")

  local cf=()
  while IFS= read -r kv; do
    if [ -n "$kv" ]; then cf+=("$kv"); fi
  done < <(cache_flags "$image")

  if use_buildx; then
    ensure_builder
    echo "build.sh: buildx $image:$tag ${cf[*]:-(no cache)}" >&2
    docker buildx build --builder "$builder" --load --progress=plain \
      ${cf[@]+"${cf[@]}"} "${flags[@]}" .
    if [ -n "$registry" ]; then push_parent_ref "$image"; fi
  else
    DOCKER_BUILDKIT=1 docker build --progress=plain ${cf[@]+"${cf[@]}"} "${flags[@]}" .
  fi
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
    # QUASAR_VERIFY_ASSUME_BUILT: the image was just built by this script, so the
    # verify must CHECK it, not rebuild it. Three of the verify scripts double as
    # standalone entry points and build the image themselves; without this they
    # re-enter the builder from inside the Verify step, and a stale image gets
    # quietly repaired instead of failing the check.
    QUASAR_IMAGE_TAG="$tag" QUASAR_VERIFY_ASSUME_BUILT=1 "$REPO_ROOT/$script"
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

# graph.sh emits one image name per line and an image name can never contain
# whitespace, so the unquoted expansions below are the intended word split.
# shellcheck disable=SC2046
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
