#!/usr/bin/env bash
set -euo pipefail

# Smoke checks for quasar-unigine. Everything here runs WITHOUT a GPU, a
# compositor socket, or an X server — this asserts the image is assembled
# correctly, not that the benchmark scores well. Live streaming validation is a
# separate exercise (quasar docs/design/research/2026-08-17-unigine-bench-workload.md).
#
#   ./scripts/verify-unigine.sh              # verify quasar-unigine:dev, building it first
#   IMAGE=quasar-unigine:x ./scripts/verify-unigine.sh --no-build

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# shellcheck source=scripts/lib/verify-lib.sh
. "$root/scripts/lib/verify-lib.sh"
qv_init

image="${IMAGE:-quasar-unigine:${QUASAR_IMAGE_TAG:-dev}}"
qv_ensure_built quasar-unigine "$@"

pass() { qv_pass "$@"; }

# --- image metadata ----------------------------------------------------------
labels="$(docker image inspect "$image" --format '{{json .Config.Labels}}')"
jq -e '.["org.quasar.image.contract"] == "1"
       and .["org.quasar.image.acceleration"] == "required"
       and .["org.quasar.image.persist"] == "/home/quasar"' <<<"$labels" >/dev/null
pass "labels: contract=1 acceleration=required persist=/home/quasar"

# --- the Wayland->X11 bridge has to actually be in the image -----------------
# Without gamescope (and the Xwayland it drags in) an X11/GLX benchmark has no
# display at all under Quasar's Wayland-only session. This is the single most
# load-bearing packaging assertion in the image.
qv_image_has "$image" gamescope Xwayland
pass "gamescope + Xwayland present"

# --- benchmark payloads ------------------------------------------------------
have_super="$(docker run --rm --entrypoint /bin/bash "$image" -lc \
  '[[ -x /opt/unigine/superposition/bin/superposition ]] && echo 1 || echo 0')"

docker run --rm --entrypoint /bin/bash "$image" -lc "$QV_GUARD"'
  [[ -x /opt/unigine/heaven/bin/heaven_x64 ]]
  [[ -f /opt/unigine/heaven/data/heaven_4.0.cfg ]]
  # The engine rewrites engine_config on exit; a read-only data dir wedges every
  # pass after the first.
  [[ -w /opt/unigine/heaven/data ]]
  # x86 halves must have been stripped — they are ~90 MB this image can never use.
  [[ ! -e /opt/unigine/heaven/bin/heaven_x86 ]]
'
pass "heaven: binary + config present, data dir writable, x86 stripped"

# Dynamic-link closure: quasar-app does not carry libXinerama/libXrandr/libXrender,
# so a base-image refresh that drops them must fail here rather than at first launch.
docker run --rm --entrypoint /bin/bash "$image" -lc "$QV_GUARD"'
  export LD_LIBRARY_PATH=/opt/unigine/heaven/bin/x64:/opt/unigine/heaven/bin
  missing="$(ldd /opt/unigine/heaven/bin/heaven_x64 | grep -F "not found" || true)"
  if [[ -n "$missing" ]]; then echo "unresolved sonames:"; echo "$missing"; exit 1; fi
'
pass "heaven: no unresolved shared libraries"

if [[ "$have_super" == "1" ]]; then
  docker run --rm --entrypoint /bin/bash "$image" -lc '
    set -e
    [[ -x /opt/unigine/superposition/bin/superposition ]]
    [[ -w /opt/unigine/superposition/data ]]
    export LD_LIBRARY_PATH=/opt/unigine/superposition/bin/x64:/opt/unigine/superposition/bin
    missing="$(ldd /opt/unigine/superposition/bin/superposition | grep -F "not found" || true)"
    if [[ -n "$missing" ]]; then echo "unresolved sonames:"; echo "$missing"; exit 1; fi
  '
  pass "superposition: binary present, data dir writable, no unresolved libraries"
else
  printf 'SKIP  superposition not in this image (built with WITH_SUPERPOSITION=0)\n'
fi

# --- launcher configuration path ---------------------------------------------
# UNIGINE_DRY_RUN exercises env parsing -> install lookup -> command construction
# and exits before gamescope, so it needs no GPU.
# QUASAR_GPU_PROBE_ON_STARTUP=0: quasar-app's startup probe fails closed with no
# GPU, and these checks deliberately need neither a GPU nor a compositor.
dry() { docker run --rm -e QUASAR_GPU_PROBE_ON_STARTUP=0 -e UNIGINE_DRY_RUN=1 "$@" "$image"; }

out="$(dry -e UNIGINE_BENCH=heaven \
        -e UNIGINE_WIDTH=1280 -e UNIGINE_HEIGHT=720 -e UNIGINE_QUALITY=ultra)"
grep -q 'dry-run bench=heaven mode=1280x720' <<<"$out"
grep -q 'QUALITY_ULTRA' <<<"$out"
grep -q '\-video_width 1280' <<<"$out"
grep -q 'PHORONIX' <<<"$out"
pass "launcher dry-run: heaven 1280x720 QUALITY_ULTRA, PHORONIX define present"

# QUASAR_STREAM_* is how Quasar injects the negotiated session mode (quasar#384).
# A baked or defaulted resolution that shadows it is the exact defect that made a
# 1440p120 Steam session render 1080p60 — assert the fallback order explicitly.
out="$(dry -e QUASAR_STREAM_WIDTH=2560 -e QUASAR_STREAM_HEIGHT=1440)"
grep -q 'mode=2560x1440' <<<"$out"
pass "launcher honours QUASAR_STREAM_WIDTH/HEIGHT when UNIGINE_WIDTH is unset"

# Bad input must fail closed, not silently launch something else.
if dry -e UNIGINE_BENCH=nope >/dev/null 2>&1; then
  echo "FAIL: an unknown UNIGINE_BENCH was accepted"; exit 1
fi
if dry -e UNIGINE_QUALITY=insane >/dev/null 2>&1; then
  echo "FAIL: an unknown UNIGINE_QUALITY was accepted"; exit 1
fi
pass "launcher rejects unknown UNIGINE_BENCH / UNIGINE_QUALITY"

echo "quasar-unigine checks passed ($image)"
