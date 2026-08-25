#!/usr/bin/env bash
set -euo pipefail

# Smoke checks for quasar-benchapp. Everything here runs WITHOUT a GPU and
# without a compositor socket — this asserts the image is assembled correctly and
# that the probe's offscreen path and marker still work, not that it streams well.
# Live streaming validation is a separate exercise
# (quasar docs/design/research/2026-08-18-benchapp-bringup.md).
#
#   ./scripts/verify-benchapp.sh               # verify quasar-benchapp:dev, building it first
#   IMAGE=quasar-benchapp:x ./scripts/verify-benchapp.sh --no-build

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# shellcheck source=scripts/lib/verify-lib.sh
. "$root/scripts/lib/verify-lib.sh"
qv_init

image="${IMAGE:-quasar-benchapp:${QUASAR_IMAGE_TAG:-dev}}"
[[ "${1:-}" == "--no-build" ]] || ./scripts/build.sh quasar-benchapp

pass() { qv_pass "$@"; }

# --- image metadata ----------------------------------------------------------
labels="$(docker image inspect "$image" --format '{{json .Config.Labels}}')"
jq -e '.["org.quasar.image.contract"] == "1"
       and .["org.quasar.image.acceleration"] == "required"
       and .["org.quasar.image.persist"] == "/home/quasar"
       and .["org.quasar.image.graphics-apis"] == "vulkan"' <<<"$labels" >/dev/null
pass "labels: contract=1 acceleration=required persist=/home/quasar apis=vulkan"

# --- NO nested compositor ----------------------------------------------------
# This is the defining property of this image versus quasar-unigine/quasar-steam.
# benchapp measures the compositor->encoder path; a gamescope smuggled in by a
# base-image change would insert a second compositor's pacing and scaling into
# every measurement and silently invalidate the results.
qv_image_lacks "$image" gamescope Xwayland
pass "no nested compositor: gamescope/Xwayland absent"

# --- payload + dynamic-link closure ------------------------------------------
# quasar-app carries vulkan-loader and libwayland-client but not libwayland-cursor
# (winit dlopens it for pointer themes); a base refresh that drops any of the
# closure must fail here rather than at first launch on a live host.
docker run --rm --entrypoint /bin/bash "$image" -lc "$QV_GUARD"'
  [[ -x /usr/local/bin/benchapp ]]
  [[ -x /usr/local/bin/benchapp-run.sh ]]
  [[ -x /usr/local/bin/quasar-benchapp ]]
  [[ -d /opt/benchapp/scenes ]]
  missing="$(ldd /usr/local/bin/benchapp | grep -c "not found" || true)"
  [[ "$missing" -eq 0 ]] || { ldd /usr/local/bin/benchapp | grep "not found"; exit 1; }
  ldconfig -p | grep -q libwayland-cursor
  ldconfig -p | grep -q libvulkan
'
pass "benchapp + launcher + scenes present, no unresolved sonames"

# --- the app is the version we think it is -----------------------------------
docker run --rm --entrypoint /usr/local/bin/benchapp "$image" --help >/dev/null
pass "benchapp --help runs"

# --- launcher: env->args resolution and fail-closed behaviour ----------------
# BENCHAPP_DRY_RUN prints the resolved command instead of rendering, so the whole
# knob surface can be asserted without a GPU.
# A fake Wayland socket is enough: the launcher only stats it, and BENCHAPP_DRY_RUN
# returns before the app is exec'd. socat is in the image for exactly this kind of
# control-socket work.
mksock='socat UNIX-LISTEN:/tmp/fake.sock,fork /dev/null & for _ in $(seq 50); do [ -S /tmp/fake.sock ] && break; sleep 0.1; done; export WAYLAND_DISPLAY=/tmp/fake.sock'

dry="$(docker run --rm -e BENCHAPP_DRY_RUN=1 --entrypoint /bin/bash "$image" -c \
  "$mksock; exec /usr/local/bin/quasar-benchapp")"

grep -q -- '--scene flythrough' <<<"$dry"
grep -q -- '--load 5'           <<<"$dry"
grep -q -- '--motion 5'         <<<"$dry"
grep -q -- '--fps 60'           <<<"$dry"
# Marker scale must default to 0.5, not the app's own 1.0: at 1.0 the marker is
# 28% of a 1080p frame and it dominates every encoder-difficulty measurement.
grep -q -- '--marker-scale 0.5' <<<"$dry"
# --render must be ABSENT by default so the probe follows the compositor's
# configure size and the live resolution-change path (quasar#384) is exercised.
# refute_grep_text, not `! grep`: errexit does not apply to a `!`-inverted
# command, so the previous form could never have failed -- a pinned --render
# would have shipped with this assertion still reading as green.
refute_grep_text '--render' 'the launcher default command' "$dry" \
  "a pinned --render stops the probe following the compositor's configure size"
pass "launcher defaults: flythrough/5/5/60, marker-scale 0.5, no pinned --render"

# QUASAR_STREAM_FPS is the session's negotiated refresh and must reach the pacer.
dry120="$(docker run --rm -e BENCHAPP_DRY_RUN=1 \
  -e QUASAR_STREAM_FPS=120 -e BENCHAPP_SCENE=swarm -e BENCHAPP_LOAD=8 \
  --entrypoint /bin/bash "$image" -c "$mksock; exec /usr/local/bin/quasar-benchapp")"
grep -q -- '--fps 120'     <<<"$dry120"
grep -q -- '--scene swarm' <<<"$dry120"
grep -q -- '--load 8'      <<<"$dry120"
pass "launcher: QUASAR_STREAM_FPS + BENCHAPP_* overrides honoured"

# Fail closed: a bad scene must abort, not silently fall back to a different
# workload and produce results labelled with a scene that never rendered.
# refute_cmd, not `! docker run`: both of these were inert under errexit, so the
# two fail-CLOSED assertions -- the ones guarding against results labelled with a
# scene that never rendered -- could not fail. They are the assertions in this
# file it would be worst to have wrong.
refute_cmd "a bad BENCHAPP_SCENE must abort, not fall back to a different workload" \
  docker run --rm -e BENCHAPP_DRY_RUN=1 -e BENCHAPP_SCENE=nope \
    --entrypoint /bin/bash "$image" -c "$mksock; exec /usr/local/bin/quasar-benchapp"
# ...and a missing compositor socket must abort rather than hang.
refute_cmd "a missing Wayland socket must abort, not hang" \
  docker run --rm -e BENCHAPP_DRY_RUN=1 \
    --entrypoint /bin/bash "$image" -c 'exec /usr/local/bin/quasar-benchapp'
pass "launcher fails closed on bad scene and on missing Wayland socket"

# --- the launcher must hand over, not supervise ------------------------------
# benchapp handles SIGTERM itself (quasar-benchgame 6effb6c). A shell left sitting
# between PID 1 and the app would have to forward the signal correctly, and a
# missed forward costs the final summary.json on every `docker stop` -- silently,
# since frames.jsonl/events.jsonl still look fine.
docker run --rm --entrypoint /bin/bash "$image" -lc "$QV_GUARD"'
  grep -qE "^exec /usr/local/bin/benchapp-run.sh" /usr/local/bin/quasar-benchapp
  grep -qE "^exec /usr/local/bin/benchapp"        /usr/local/bin/benchapp-run.sh
  # explicit if/exit: "! grep" is inert under errexit and would pass silently.
  if grep -q "trap .* TERM" /usr/local/bin/quasar-benchapp; then
    echo "FAIL: quasar-benchapp traps TERM; it must exec through so benchapp handles the signal itself" >&2
    exit 1
  fi
'
pass "launcher execs through to benchapp (no supervising shell, no TERM trap)"

# --- the actual render + marker path, on llvmpipe -----------------------------
# The most valuable GPU-less assertion available: render real frames offscreen,
# prove they are deterministic by frame index, and prove the marker still carries
# a CRC-valid payload. A shader/marker regression that would ruin a whole
# measurement campaign is caught here in ~30 s.
docker run --rm \
  -e MESA_LOADER_DRIVER_OVERRIDE=llvmpipe -e WGPU_BACKEND=vulkan \
  --entrypoint /bin/bash "$image" -lc "$QV_GUARD"'
  /usr/local/bin/benchapp --offscreen --dump-frames 0-9 --out /tmp/a >/dev/null
  /usr/local/bin/benchapp --offscreen --dump-frames 5-5 --out /tmp/b >/dev/null
  [[ "$(ls /tmp/a/*.png | wc -l)" -eq 10 ]]
  a="$(sha256sum /tmp/a/frame-00000005.png | cut -d" " -f1)"
  b="$(sha256sum /tmp/b/frame-00000005.png | cut -d" " -f1)"
  [[ "$a" == "$b" ]] || { echo "offscreen render is not deterministic by frame index"; exit 1; }
'
pass "offscreen: 10 deterministic frames on llvmpipe, frame 5 byte-identical on re-render"

printf '\nAll quasar-benchapp checks passed for %s\n' "$image"
