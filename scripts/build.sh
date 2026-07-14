#!/usr/bin/env bash
set -euo pipefail

target="${1:-graphics-fedora}"
version="$(tr -d '[:space:]' < VERSION)"
tag="${QUASAR_IMAGE_TAG:-dev}"
declare -a args=()

case "$target" in
  base-fedora) context=. dockerfile=images/base-fedora/Dockerfile ;;
  graphics-fedora) context=. dockerfile=images/graphics-fedora/Dockerfile; args=(--build-arg "BASE_IMAGE=quasar/base-fedora:${tag}") ;;
  browser-fedora) context=. dockerfile=images/browser-fedora/Dockerfile; args=(--build-arg "GRAPHICS_IMAGE=quasar/graphics-fedora:${tag}") ;;
  game-fedora) context=. dockerfile=images/game-fedora/Dockerfile; args=(--build-arg "GRAPHICS_IMAGE=quasar/graphics-fedora:${tag}") ;;
  diagnostics) context=. dockerfile=images/diagnostics/Dockerfile; args=(--build-arg "BROWSER_IMAGE=quasar/browser-fedora:${tag}") ;;
  test-vulkan) context=. dockerfile=images/test-vulkan/Dockerfile; args=(--build-arg "GRAPHICS_IMAGE=quasar/graphics-fedora:${tag}") ;;
  test-egl) context=. dockerfile=images/test-egl/Dockerfile; args=(--build-arg "GRAPHICS_IMAGE=quasar/graphics-fedora:${tag}") ;;
  *) echo "usage: $0 {base-fedora|graphics-fedora|browser-fedora|game-fedora|diagnostics|test-vulkan|test-egl}" >&2; exit 64 ;;
esac

DOCKER_BUILDKIT=1 docker build --progress=plain -f "$dockerfile" -t "quasar/${target}:${tag}" --build-arg "VERSION=$version" "${args[@]+"${args[@]}"}" "$context"
