#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 0 || "$1" == "quasar-base" ]] || { echo "usage: $0 [quasar-base]" >&2; exit 64; }
version="$(tr -d '[:space:]' < VERSION)"
DOCKER_BUILDKIT=1 docker build --progress=plain -f images/quasar-base/Dockerfile -t "quasar-base:${QUASAR_IMAGE_TAG:-dev}" --build-arg "VERSION=$version" .
