#!/usr/bin/env bash
set -euo pipefail

target="${1:-all}"
version="$(tr -d '[:space:]' < VERSION)"
tag="${QUASAR_IMAGE_TAG:-dev}"

build() { DOCKER_BUILDKIT=1 docker build --progress=plain "$@" .; }
build_base() { build -f images/quasar-base/Dockerfile -t "quasar-base:$tag" --build-arg "VERSION=$version"; }
build_app() { build -f images/quasar-app/Dockerfile -t "quasar-app:$tag" --build-arg "BASE_IMAGE=quasar-base:$tag" --build-arg "VERSION=$version"; }
build_diagnostics() { build -f images/quasar-diagnostics/Dockerfile -t "quasar-diagnostics:$tag" --build-arg "APP_IMAGE=quasar-app:$tag" --build-arg "VERSION=$version"; }
build_vulkan() { build -f images/quasar-test-vulkan/Dockerfile -t "quasar-test-vulkan:$tag" --build-arg "APP_IMAGE=quasar-app:$tag" --build-arg "VERSION=$version"; }
build_egl() { build -f images/quasar-test-egl/Dockerfile -t "quasar-test-egl:$tag" --build-arg "APP_IMAGE=quasar-app:$tag" --build-arg "VERSION=$version"; }
build_steam_runtime() { build -f images/quasar-steam-runtime/Dockerfile -t "quasar-steam-runtime:$tag" --build-arg "APP_IMAGE=quasar-app:$tag" --build-arg "VERSION=$version"; }
build_steam() { build -f images/quasar-steam/Dockerfile -t "quasar-steam:$tag" --build-arg "APP_IMAGE=quasar-app:$tag" --build-arg "STEAM_RUNTIME_IMAGE=quasar-steam-runtime:$tag" --build-arg "VERSION=$version"; }
build_kde() { build -f images/quasar-kde/Dockerfile -t "quasar-kde:$tag" --build-arg "STEAM_RUNTIME_IMAGE=quasar-steam-runtime:$tag" --build-arg "VERSION=$version"; }

case "$target" in
  quasar-base) build_base ;;
  quasar-app) build_base; build_app ;;
  quasar-diagnostics) build_base; build_app; build_diagnostics ;;
  quasar-test-vulkan) build_base; build_app; build_vulkan ;;
  quasar-test-egl) build_base; build_app; build_egl ;;
  quasar-steam-runtime) build_base; build_app; build_steam_runtime ;;
  quasar-steam) build_base; build_app; build_steam_runtime; build_steam ;;
  quasar-kde) build_base; build_app; build_steam_runtime; build_kde ;;
  all) build_base; build_app; build_diagnostics; build_vulkan; build_egl; build_steam_runtime; build_steam; build_kde ;;
  *) echo "usage: $0 {all|quasar-base|quasar-app|quasar-diagnostics|quasar-test-vulkan|quasar-test-egl|quasar-steam-runtime|quasar-steam|quasar-kde}" >&2; exit 64 ;;
esac
