#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 0 || "$1" == "quasar-base" ]] || { echo "usage: $0 [quasar-base]" >&2; exit 64; }
DOCKER_BUILDKIT=1 docker build --progress=plain -f images/quasar-base/Dockerfile -t "quasar-base:${QUASAR_IMAGE_TAG:-dev}" .
