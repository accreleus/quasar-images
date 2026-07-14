#!/usr/bin/env bash
# Container-level validation of quasar-steam launcher wiring WITHOUT a live
# display/GPU/audio. Stubs `gamescope` so the launcher's computed argv + env are
# captured instead of actually starting a compositor.
set -euo pipefail
IMG="${1:-quasar-steam:dev}"

# Stub gamescope: print its argv + the env the launcher computed, then exit
# (do not run the real Steam client).
STUB='mkdir -p /tmp/bin
cat >/tmp/bin/gamescope <<"EOF"
#!/bin/bash
echo "GAMESCOPE_ARGV: $*"
echo "STEAM_STARTUP_FLAGS=[$STEAM_STARTUP_FLAGS]"
echo "STEAM_MULTIPLE_XWAYLANDS=${STEAM_MULTIPLE_XWAYLANDS:-<unset>}"
EOF
chmod +x /tmp/bin/gamescope
export PATH=/tmp/bin:$PATH
exec /usr/local/bin/quasar-steam'

run_mode() {
  local label="$1"; shift
  echo "===== $label ====="
  docker run --rm --entrypoint /bin/bash "$@" "$IMG" -lc "$STUB"
  echo
}

echo "### A. bigpicture (default) — expect -bigpicture, multi-xwayland unset"
run_mode "default(bigpicture)"

echo "### B. gamepadui — expect full deck unit + STEAM_MULTIPLE_XWAYLANDS=1"
run_mode "gamepadui" -e QUASAR_STEAM_UI_MODE=gamepadui

echo "### C. STEAM_STARTUP_FLAGS override is respected verbatim"
run_mode "override" -e STEAM_STARTUP_FLAGS="-tenfoot -foo"

echo "### D. /dev/shm warning fires on default 64MB shm (no --shm-size)"
docker run --rm --entrypoint /bin/bash "$IMG" -lc "$STUB" 2>&1 | grep -i 'shm' || echo "NO shm warning (unexpected)"
echo

echo "### E. large shm suppresses the warning"
docker run --rm --shm-size=1g --entrypoint /bin/bash "$IMG" -lc "$STUB" 2>&1 | grep -i 'shm' && echo "UNEXPECTED shm warning with 1g" || echo "OK: no shm warning at 1g"
echo

echo "### F. asound.conf present and routes to pulse"
docker run --rm --entrypoint /bin/bash "$IMG" -lc 'cat /etc/asound.conf | grep -E "type pulse|fallback"'
echo

echo "### G. PUID/PGID honoured at unraid 99:100 (real entrypoint drops privileges)"
docker run --rm -e PUID=99 -e PGID=100 -e QUASAR_GPU_PROBE_ON_STARTUP=0 "$IMG" id
echo

echo "### H. WAYLAND_DISPLAY is unset for the Steam client"
docker run --rm --entrypoint /bin/bash "$IMG" -lc 'grep -n "unset WAYLAND_DISPLAY" /usr/local/bin/quasar-steam-client'
echo

echo "### I. 32-bit GL userspace present in image (driver libs still injected at runtime)"
docker run --rm --entrypoint /bin/bash "$IMG" -lc 'file /usr/lib/libGL.so.1; ls -1 /usr/lib/*.so* | grep -c EGL'
echo

echo "ALL RUNTIME VALIDATIONS EXECUTED"
