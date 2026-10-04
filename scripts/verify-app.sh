#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# shellcheck source=scripts/lib/verify-lib.sh
. "$root/scripts/lib/verify-lib.sh"
qv_init

# The image under test. `scripts/build.sh` tags what it builds with
# $QUASAR_IMAGE_TAG (default `dev`), so a verify script that hardcodes `:dev`
# silently checks a DIFFERENT image than the one just built. Honour the same
# variable the builder uses, and allow an explicit override.
TAG="${QUASAR_IMAGE_TAG:-dev}"
APP_IMAGE="${QUASAR_APP_IMAGE:-quasar-app:$TAG}"

# --- The display-mode bridge (quasar #445, moved here by quasar-images#447) --
# It used to be built per-desktop-image (quasar-xfce); it now lives in the
# shared spine so every current and future X11 desktop image inherits it with
# no re-implementation. Three things must hold: the binary (and its
# compatibility symlink) are on PATH, the builder toolchain it needed did not
# leak into the runtime image, and it refuses to run with no parent compositor
# named.
echo "checking the display-mode bridge in $APP_IMAGE"
qv_image_has "$APP_IMAGE" quasar-display-bridge quasar-xfce-modes

qv_image_lacks "$APP_IMAGE" gcc make wayland-scanner pkg-config

docker run --rm --entrypoint /bin/bash "$APP_IMAGE" -lc "$QV_GUARD"'
  # Misuse contract: no QUASAR_PARENT_WAYLAND_DISPLAY -> exit 2, never a hang
  # and never success. Checked through both names: the real binary and the
  # quasar-xfce-modes compatibility symlink. The command sits on the left of a
  # `||`, one of the contexts the ERR trap deliberately skips (bash(1),
  # "Signals"), so an expected non-zero exit here does not itself print a
  # spurious FAIL from $QV_GUARD.
  rc=0
  quasar-display-bridge >/tmp/bridge.out 2>&1 || rc=$?
  if [[ "$rc" != 2 ]]; then
    echo "FAIL: quasar-display-bridge exited $rc with no QUASAR_PARENT_WAYLAND_DISPLAY, want 2" >&2
    cat /tmp/bridge.out >&2
    exit 1
  fi

  rc=0
  quasar-xfce-modes >/tmp/bridge2.out 2>&1 || rc=$?
  if [[ "$rc" != 2 ]]; then
    echo "FAIL: the quasar-xfce-modes symlink exited $rc with no QUASAR_PARENT_WAYLAND_DISPLAY, want 2" >&2
    cat /tmp/bridge2.out >&2
    exit 1
  fi

  link_target="$(readlink -f /usr/local/bin/quasar-xfce-modes)"
  if [[ "$link_target" != /usr/local/bin/quasar-display-bridge ]]; then
    echo "FAIL: quasar-xfce-modes must be a compatibility symlink to quasar-display-bridge, got $link_target" >&2
    exit 1
  fi

  # Runtime libraries the binary actually needs must resolve -- ldd is part of
  # glibc-common, already in this image, so no extra dependency to check it.
  for lib in libwayland-client libX11 libXrandr; do
    if ! ldd /usr/local/bin/quasar-display-bridge | grep -q "$lib"; then
      echo "FAIL: /usr/local/bin/quasar-display-bridge does not link $lib" >&2
      exit 1
    fi
  done
  if ldd /usr/local/bin/quasar-display-bridge | grep -q "not found"; then
    echo "FAIL: quasar-display-bridge has an unresolved runtime dependency" >&2
    ldd /usr/local/bin/quasar-display-bridge >&2
    exit 1
  fi
'

qv_pass "quasar-app display-bridge checks passed ($APP_IMAGE)"
