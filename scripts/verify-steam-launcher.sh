#!/usr/bin/env bash
# Behaviour checks for the quasar-steam launcher: the nested command line stays
# what it was, and QUASAR_DIRECT_DISPLAY=1 starts gamescope on its own DRM
# backend under seatd (quasar#457). The cases live in
# scripts/tests/steam-launcher/cases.sh and run inside the image with stubs for
# gamescope, dbus-run-session and drm_info, so no GPU is needed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# shellcheck source=scripts/lib/verify-lib.sh
. "$root/scripts/lib/verify-lib.sh"
qv_init

TAG="${QUASAR_IMAGE_TAG:-dev}"
STEAM_IMAGE="${QUASAR_STEAM_IMAGE:-quasar-steam:$TAG}"
qv_ensure_built quasar-steam "$@"

cases_dir="$root/scripts/tests/steam-launcher"
assert_file "$cases_dir/cases.sh" "the launcher behaviour cases"

echo "running the launcher behaviour cases in $STEAM_IMAGE"
# --cap-add MKNOD is in Docker's default set; the cases mknod fake /dev/snd and
# /dev/input nodes (never opened) to exercise the sound-group hook.
docker run --rm --entrypoint /bin/bash \
  -v "$cases_dir:/t:ro" \
  "$STEAM_IMAGE" /t/cases.sh

echo "quasar-steam launcher behaviour checks passed"
