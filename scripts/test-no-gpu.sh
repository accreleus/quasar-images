#!/usr/bin/env bash
set -euo pipefail

if docker run --rm -e QUASAR_GPU_HARDWARE_KEY=pci-0000:04:00.0 quasar/graphics-fedora:dev true; then
  echo "GPU probe unexpectedly passed without a GPU" >&2
  exit 1
fi

echo "no-GPU rejection passed"
