#!/usr/bin/env bash
# Behaviour cases for the quasar-steam launcher and its direct-display init
# hooks. Runs INSIDE the quasar-steam image, as root, with this directory
# mounted at /t (scripts/verify-steam-launcher.sh does that). No GPU needed:
# gamescope, dbus-run-session and drm_info are stubs that record what the
# launcher asked of them; seatd is the real daemon from the image.
#
# What is pinned here, and why:
#   * nested (QUASAR_DIRECT_DISPLAY unset): the gamescope command line and
#     environment are exactly what they were before direct display existed.
#   * direct (QUASAR_DIRECT_DISPLAY=1): gamescope runs on its DRM backend under
#     seatd, at the panel's native size and highest refresh, with GBM scanout
#     and forced composition on NVIDIA (upstream gamescope #2309); nothing of
#     the nested parent (its socket, the stream mode)
#     leaks in.
#   * the seatd and device-group hooks act only in direct mode, and no init
#     hook changes anything under /dev/input then (it is the host's directory).
#   * the Steam UI mode comes from the runtime preset (STEAM_STARTUP_FLAGS),
#     never from a baked-in image default; QUASAR_STEAM_UI_MODE is only an
#     explicit opt-in, and a plain launch with no UI-mode flag warns.
set -Eeuo pipefail
trap 'printf "FAIL: cases.sh line %s exited %s\n      %s\n" "$LINENO" "$?" "$BASH_COMMAND" >&2' ERR

T=/t
LAUNCHER=/usr/local/bin/quasar-steam
failures=0

fail() { printf 'FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }
pass() { printf 'PASS  %s\n' "$*"; }

# The app user, created the way quasar-entrypoint creates it.
getent group 1000 >/dev/null || groupadd --gid 1000 quasar
getent passwd 1000 >/dev/null || useradd --no-log-init --uid 1000 --gid 1000 --home-dir /home/quasar --create-home --shell /bin/bash quasar
APP_USER="$(getent passwd 1000 | cut -d: -f1)"
APP_GROUP="$(getent group 1000 | cut -d: -f1)"

# --- launcher cases ------------------------------------------------------------

# run_launcher <case-name> [VAR=value ...]
# Runs the launcher in a scrubbed environment with the stubs first on PATH.
# Leaves the case's records in $log.
run_launcher() {
  local name="$1"; shift
  log="/tmp/cases/$name"
  rm -rf "$log" && mkdir -p "$log/home"
  : > "$log/gamescope.args"; : > "$log/gamescope.env"; : > "$log/client.env"; : > "$log/steam.env"
  local rc=0
  env -i PATH="$T/stubs:/usr/local/bin:/usr/bin:/bin" HOME="$log/home" STUB_LOG="$log" \
    "$@" timeout 60 "$LAUNCHER" >"$log/launcher.out" 2>&1 || rc=$?
  # The gamescope stub idles like a compositor; the launcher does not kill it
  # on a clean Steam exit (nor does it in production -- the container exits).
  pkill -f "^sleep 300$" 2>/dev/null || true
  # Direct mode backgrounds the audio daemons just before exec'ing Steam; give
  # their stubs a moment to write before the case reads the log.
  local i
  for i in $(seq 1 20); do
    [[ ! -e "$log/audio.log" || "$(wc -l < "$log/audio.log")" -ge 3 ]] && break
    sleep 0.1
  done
  if [[ "$rc" != 0 ]]; then
    fail "$name: launcher exited $rc"
    sed 's/^/      /' "$log/launcher.out" >&2
  elif [[ ! -s "$log/gamescope.args" ]]; then
    fail "$name: gamescope was never started"
    sed 's/^/      /' "$log/launcher.out" >&2
  fi
  return 0
}

# The argv gamescope got, one per line, with the per-run fifo paths after
# -R / -T replaced by placeholders so the line can be compared exactly.
gs_argv() {
  awk 'prev == "-R" { print "<ready-fifo>"; prev = ""; next }
       prev == "-T" { print "<stats-fifo>"; prev = ""; next }
       { print; prev = $0 }' "$log/gamescope.args" | paste -sd' '
}

expect_argv() {
  local name="$1" want="$2" got
  got="$(gs_argv)"
  if [[ "$got" == "$want" ]]; then
    pass "$name: gamescope $got"
  else
    fail "$name: gamescope argv"
    printf '      want: %s\n      got:  %s\n' "$want" "$got" >&2
  fi
}

# expect_env <file> <name> VAR=value|VAR<unset>
expect_env() {
  local file="$1" name="$2" line="$3"
  if grep -qxF -- "$line" "$log/$file"; then
    pass "$name: $file has $line"
  else
    fail "$name: $file should have $line; it has: $(paste -sd' ' "$log/$file")"
  fi
}

drm_info_called() { [[ -s "$log/drm_info.calls" ]]; }

# expect_launcher_log <name> <substring> / expect_no_launcher_log <name> <substring>
expect_launcher_log() {
  local name="$1" needle="$2"
  if grep -qF -- "$needle" "$log/launcher.out"; then
    pass "$name: launcher logged '$needle'"
  else
    fail "$name: launcher should have logged '$needle'; it logged: $(paste -sd' ' "$log/launcher.out")"
  fi
}
expect_no_launcher_log() {
  local name="$1" needle="$2"
  if grep -qF -- "$needle" "$log/launcher.out"; then
    fail "$name: launcher should not have logged '$needle'"
  else
    pass "$name: launcher did not log '$needle'"
  fi
}

NO_UI_WARNING="Steam is starting with no UI mode"

# 1. Nested: today's command line, byte for byte, and no direct-display state.
run_launcher nested \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 \
  QUASAR_STREAM_WIDTH=2560 QUASAR_STREAM_HEIGHT=1440 QUASAR_STREAM_FPS=120 \
  PULSE_SERVER=unix:/run/quasar-pulse/native PULSE_SINK=quasar_output
expect_argv nested "-e -b -R <ready-fifo> -T <stats-fifo> -W 2560 -H 1440 -r 120"
expect_env gamescope.env nested "WAYLAND_DISPLAY=/run/quasar-wayland/wayland-3"
expect_env gamescope.env nested "WLR_XWAYLAND<unset>"
expect_env gamescope.env nested "gamescope_drm_gbm_scanout<unset>"
expect_env gamescope.env nested "LIBSEAT_BACKEND<unset>"
expect_env client.env nested "DISPLAY=:7"
expect_env client.env nested "WAYLAND_DISPLAY<unset>"
# No baked UI-mode default: with STEAM_STARTUP_FLAGS and QUASAR_STEAM_UI_MODE
# both unset, Steam gets no UI-mode flag, and the plain-app warning fires.
expect_env client.env nested "STEAM_STARTUP_FLAGS="
expect_launcher_log nested "$NO_UI_WARNING"
expect_launcher_log nested "STEAM_STARTUP_FLAGS=-bigpicture"
if drm_info_called; then fail "nested: drm_info must not be consulted"; else pass "nested: drm_info not consulted"; fi
# Nested audio is the agent's: its PULSE_* reach Steam and no daemon starts.
expect_env client.env nested "PULSE_SERVER=unix:/run/quasar-pulse/native"
expect_env client.env nested "PULSE_SINK=quasar_output"
if [[ -s "$log/audio.log" ]]; then
  fail "nested: audio daemons started: $(paste -sd';' "$log/audio.log")"
else
  pass "nested: no audio daemon started"
fi
if [[ "$(sed -n 2p "$log/client.args")" == /usr/local/bin/quasar-steam-client ]]; then
  pass "nested: Steam runs as dbus-run-session -- quasar-steam-client"
else
  fail "nested: dbus-run-session ran $(paste -sd' ' "$log/client.args")"
fi

if [[ -e "$log/helper.env" ]]; then
  fail "nested: a launch helper started with none mounted"
else
  pass "nested: no launch helper started"
fi

# 1a. A derived Steam tile: the agent mounted its launch helper (quasar#731). It
#     starts once gamescope is ready, so it has gamescope's DISPLAY, with the
#     tile's flags and socket; the rest of the launch is case 1's.
#     Steam waits for the helper's "ready" line: the helper picks where to start
#     reading Steam's log on its first look, so Steam must not have written yet.
run_launcher launch-helper \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 \
  STEAM_STARTUP_FLAGS="-bigpicture -applaunch 620" \
  QUASAR_LAUNCH_HELPER="$T/stubs/launch-helper" \
  QUASAR_LAUNCH_SOCKET=/run/quasar-launch/launch.sock STUB_HELPER_DELAY=0.5
expect_env helper.env launch-helper "DISPLAY=:7"
expect_env helper.env launch-helper "STEAM_STARTUP_FLAGS=-bigpicture -applaunch 620"
expect_env helper.env launch-helper "QUASAR_LAUNCH_SOCKET=/run/quasar-launch/launch.sock"
expect_argv launch-helper "-e -b -R <ready-fifo> -T <stats-fifo> -W 1920 -H 1080 -r 60"
expect_env client.env launch-helper "DISPLAY=:7"
if [[ -e "$log/helper.ready" && "$log/client.env" -nt "$log/helper.ready" ]]; then
  pass "launch-helper: Steam started after the helper was ready"
else
  fail "launch-helper: Steam started before the helper's ready line"
fi

# 1a-bound. A helper that never says ready holds Steam back 2 s, not longer.
t0=$(date +%s%N)
run_launcher launch-helper-hangs \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 \
  STEAM_STARTUP_FLAGS="-bigpicture -applaunch 620" \
  QUASAR_LAUNCH_HELPER="$T/stubs/launch-helper" STUB_HELPER_HANG=1
waited_ms=$(( ($(date +%s%N) - t0) / 1000000 ))
expect_env client.env launch-helper-hangs "DISPLAY=:7"
if (( waited_ms >= 2000 && waited_ms < 10000 )) && grep -q 'not ready within 2s; starting Steam anyway' "$log/launcher.out"; then
  pass "launch-helper-hangs: Steam started after the 2 s bound (${waited_ms} ms) and the launcher said so"
else
  fail "launch-helper-hangs: ${waited_ms} ms; launcher said: $(grep 'launch helper' "$log/launcher.out" | paste -sd';')"
fi

# 1a''. A mount that is not executable (a host whose /run is noexec): the launcher
#       runs a private copy, with the same environment.
cp "$T/stubs/launch-helper" /tmp/launch-helper-noexec && chmod 0644 /tmp/launch-helper-noexec
run_launcher launch-helper-noexec \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 \
  STEAM_STARTUP_FLAGS="-bigpicture -applaunch 620" \
  QUASAR_LAUNCH_HELPER=/tmp/launch-helper-noexec \
  QUASAR_LAUNCH_SOCKET=/run/quasar-launch/launch.sock
expect_env helper.env launch-helper-noexec "DISPLAY=:7"
expect_env helper.env launch-helper-noexec "QUASAR_LAUNCH_SOCKET=/run/quasar-launch/launch.sock"
if [[ -x "$log/home/.runtime/quasar-launch-helper" ]]; then
  pass "launch-helper-noexec: ran the copy in the private runtime dir"
else
  fail "launch-helper-noexec: no executable copy in $log/home/.runtime"
fi

# 1a-restart. A helper that dies while Steam runs is started again.
run_launcher launch-helper-restart \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 \
  STEAM_STARTUP_FLAGS="-bigpicture -applaunch 620" \
  QUASAR_LAUNCH_HELPER="$T/stubs/launch-helper" STUB_HELPER_EXIT_FIRST=137 STUB_STEAM_SECONDS=2
if [[ "$(wc -l < "$log/helper.starts")" == 2 ]] && grep -q 'launch helper exited 137; restarting it' "$log/launcher.out"; then
  pass "launch-helper-restart: a killed helper was started again, once"
else
  fail "launch-helper-restart: $(wc -l < "$log/helper.starts") start(s); launcher said: $(grep 'launch helper' "$log/launcher.out" | paste -sd';')"
fi

# 1a-restart-bound. One that keeps dying is restarted 3 times a minute, not more.
run_launcher launch-helper-restart-bound \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 \
  STEAM_STARTUP_FLAGS="-bigpicture -applaunch 620" \
  QUASAR_LAUNCH_HELPER="$T/stubs/launch-helper" STUB_HELPER_EXIT=1 STUB_STEAM_SECONDS=2
if [[ "$(wc -l < "$log/helper.starts")" == 4 ]] && grep -q '3 restarts this minute' "$log/launcher.out"; then
  pass "launch-helper-restart-bound: 1 start + 3 restarts, then a logged wait"
else
  fail "launch-helper-restart-bound: $(wc -l < "$log/helper.starts") start(s); launcher said: $(grep 'launch helper' "$log/launcher.out" | paste -sd';')"
fi

# 1a-clean-exit. A helper that exits 0 has nothing to watch and is left alone.
run_launcher launch-helper-clean-exit \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 \
  QUASAR_LAUNCH_HELPER="$T/stubs/launch-helper" STUB_STEAM_SECONDS=1
if [[ "$(wc -l < "$log/helper.starts")" == 1 ]] && ! grep -q restarting "$log/launcher.out"; then
  pass "launch-helper-clean-exit: not restarted"
else
  fail "launch-helper-clean-exit: $(wc -l < "$log/helper.starts") start(s)"
fi

# 1a-not-ready. A first line other than "ready" is not the handshake.
cp "$T/stubs/launch-helper" /tmp/launch-helper-chatty
sed -i 's/^echo ready$/echo hello/' /tmp/launch-helper-chatty
run_launcher launch-helper-not-ready \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 \
  QUASAR_LAUNCH_HELPER=/tmp/launch-helper-chatty
if grep -q 'not ready within 2s; starting Steam anyway' "$log/launcher.out"; then
  pass "launch-helper-not-ready: only an exact ready line counts"
else
  fail "launch-helper-not-ready: launcher said: $(grep 'launch helper' "$log/launcher.out" | paste -sd';')"
fi

# 1a-noexec-fifo / -symlink. Whatever an earlier session left where the copy goes is
# replaced, never opened or followed: a FIFO there must not hang Steam's start, and a
# symlink must not be written through.
cp "$T/stubs/launch-helper" /tmp/launch-helper-noexec && chmod 0644 /tmp/launch-helper-noexec
rm -rf /tmp/rt-fifo /tmp/rt-link /tmp/link-victim
mkdir -p /tmp/rt-fifo /tmp/rt-link
mkfifo /tmp/rt-fifo/quasar-launch-helper
echo victim > /tmp/link-victim
ln -s /tmp/link-victim /tmp/rt-link/quasar-launch-helper
for planted in fifo link; do
  t0=$(date +%s%N)
  run_launcher "launch-helper-noexec-$planted" \
    XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 \
    QUASAR_STEAM_RUNTIME_DIR="/tmp/rt-$planted" \
    QUASAR_LAUNCH_HELPER=/tmp/launch-helper-noexec
  waited_ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  dest="/tmp/rt-$planted/quasar-launch-helper"
  if [[ -f "$dest" && ! -L "$dest" && -x "$dest" && -e "$log/helper.ready" ]] && (( waited_ms < 2000 )); then
    pass "launch-helper-noexec-$planted: the copy replaced it and ran (${waited_ms} ms)"
  else
    fail "launch-helper-noexec-$planted: $(ls -l "$dest" 2>&1), ${waited_ms} ms"
  fi
done
if [[ "$(cat /tmp/link-victim)" == victim ]]; then
  pass "launch-helper-noexec-link: the symlink's target is untouched"
else
  fail "launch-helper-noexec-link: the copy was written through the symlink"
fi

# 1a'. A helper path that is not there, or a helper that dies at once, changes
#      nothing: Steam still starts and the launcher still exits 0.
run_launcher launch-helper-missing \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 \
  QUASAR_LAUNCH_HELPER=/run/quasar-launch-helper
expect_env client.env launch-helper-missing "DISPLAY=:7"
t0=$(date +%s%N)
run_launcher launch-helper-fails \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 \
  QUASAR_LAUNCH_HELPER=/bin/false
waited_ms=$(( ($(date +%s%N) - t0) / 1000000 ))
expect_env client.env launch-helper-fails "DISPLAY=:7"
if (( waited_ms < 2000 )); then
  pass "launch-helper-fails: a helper that exits does not hold Steam back (${waited_ms} ms)"
else
  fail "launch-helper-fails: Steam waited ${waited_ms} ms for a helper that had exited"
fi

# 1b. Nested with anything other than exactly "1" stays nested.
run_launcher nested-not-one \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 QUASAR_DIRECT_DISPLAY=true
expect_argv nested-not-one "-e -b -R <ready-fifo> -T <stats-fifo> -W 1920 -H 1080 -r 60"
expect_env gamescope.env nested-not-one "gamescope_drm_gbm_scanout<unset>"

# 2. Direct on the console host's shape: NVIDIA, one 4K panel whose preferred
#    mode is 60 Hz and whose best mode at that size is 240 Hz. The agent may
#    still hand over a parent socket and a stream mode; both must be ignored.
run_launcher direct-nvidia \
  QUASAR_DIRECT_DISPLAY=1 STEAM_STARTUP_FLAGS=-bigpicture STUB_DRM_INFO="$T/fixtures/nvidia-4k240.json" \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 DISPLAY=:99 \
  QUASAR_STREAM_WIDTH=1920 QUASAR_STREAM_HEIGHT=1080 QUASAR_STREAM_FPS=60 \
  PULSE_SERVER=unix:/run/quasar-pulse/native PULSE_SINK=quasar_output \
  PULSE_SOURCE=quasar_input PULSE_COOKIE=/run/quasar-pulse/cookie
expect_argv direct-nvidia "--backend drm -e -R <ready-fifo> -T <stats-fifo> -W 3840 -H 2160 -r 240 --force-composition"
expect_env gamescope.env direct-nvidia "gamescope_drm_gbm_scanout=1"
expect_env gamescope.env direct-nvidia "LIBSEAT_BACKEND=seatd"
expect_env gamescope.env direct-nvidia "WAYLAND_DISPLAY<unset>"
expect_env gamescope.env direct-nvidia "DISPLAY<unset>"
expect_env gamescope.env direct-nvidia "WLR_XWAYLAND<unset>"
expect_env client.env direct-nvidia "DISPLAY=:7"
expect_env client.env direct-nvidia "WAYLAND_DISPLAY<unset>"
expect_env client.env direct-nvidia "STEAM_STARTUP_FLAGS=-bigpicture"
expect_no_launcher_log direct-nvidia "$NO_UI_WARNING"
# Direct audio: PipeWire first, then WirePlumber and the Pulse shim, all with the
# launcher's private runtime dir and in the same session bus Steam then gets;
# the agent's PULSE_* never reach Steam.
priv_rt="$log/home/.runtime"
bus="unix:path=$log/stub-bus"
if [[ "$(sed -n 2p "$log/client.args")" == /usr/local/libexec/quasar-steam/direct-session ]]; then
  pass "direct-nvidia: Steam runs as dbus-run-session -- direct-session"
else
  fail "direct-nvidia: dbus-run-session ran $(paste -sd' ' "$log/client.args")"
fi
if [[ "$(head -n1 "$log/audio.log" 2>/dev/null | cut -d' ' -f1)" == pipewire ]]; then
  pass "direct-nvidia: pipewire started first"
else
  fail "direct-nvidia: first audio daemon was '$(head -n1 "$log/audio.log" 2>/dev/null)'"
fi
for daemon in pipewire wireplumber pipewire-pulse; do
  if grep -qxF "$daemon XDG_RUNTIME_DIR=$priv_rt DBUS_SESSION_BUS_ADDRESS=$bus" "$log/audio.log" 2>/dev/null; then
    pass "direct-nvidia: $daemon started in Steam's bus with the private runtime dir"
  else
    fail "direct-nvidia: $daemon not started as expected; audio.log: $(paste -sd';' "$log/audio.log" 2>/dev/null)"
  fi
done
expect_env steam.env direct-nvidia "DBUS_SESSION_BUS_ADDRESS=$bus"
expect_env steam.env direct-nvidia "XDG_RUNTIME_DIR=$priv_rt"
for v in PULSE_SERVER PULSE_SINK PULSE_SOURCE PULSE_COOKIE; do
  expect_env steam.env direct-nvidia "$v<unset>"
done
expect_env steam.env direct-nvidia "DISPLAY=:7"
if grep -q '^/run/quasar-wayland' "$log/gamescope.env"; then
  fail "direct-nvidia: gamescope's runtime dir is the agent's socket dir"
else
  pass "direct-nvidia: gamescope's runtime dir is private"
fi

# 3. Direct on AMD: native size, highest refresh, and NO GBM switch or forced
#    composition -- the fix is for nvidia-drm, and the switch stays off elsewhere.
run_launcher direct-amd \
  QUASAR_DIRECT_DISPLAY=1 STUB_DRM_INFO="$T/fixtures/amd-1440p165.json"
expect_argv direct-amd "--backend drm -e -R <ready-fifo> -T <stats-fifo> -W 2560 -H 1440 -r 165"
expect_env gamescope.env direct-amd "gamescope_drm_gbm_scanout<unset>"
expect_env gamescope.env direct-amd "LIBSEAT_BACKEND=seatd"

# 4. Two connected panels: the launcher cannot know which one gamescope will
#    drive, so it names no mode (a -r that misses the mode gamescope lands on
#    would also mis-pace its vblank timer). An NVIDIA card is present: GBM on.
run_launcher direct-ambiguous \
  QUASAR_DIRECT_DISPLAY=1 STUB_DRM_INFO="$T/fixtures/hybrid-two-connected.json"
expect_argv direct-ambiguous "--backend drm -e -R <ready-fifo> -T <stats-fifo> --force-composition"
expect_env gamescope.env direct-ambiguous "gamescope_drm_gbm_scanout=1"

# 5. Monitor off at start: no mode named, gamescope chooses when it appears.
run_launcher direct-nothing-connected \
  QUASAR_DIRECT_DISPLAY=1 STUB_DRM_INFO="$T/fixtures/nvidia-nothing-connected.json"
expect_argv direct-nothing-connected "--backend drm -e -R <ready-fifo> -T <stats-fifo> --force-composition"

# 6. drm_info unusable: still starts, no mode named. The GBM switch can be
#    forced on by the operator when detection has nothing to go on.
run_launcher direct-no-drm-info \
  QUASAR_DIRECT_DISPLAY=1 QUASAR_STEAM_GBM_SCANOUT=1
expect_argv direct-no-drm-info "--backend drm -e -R <ready-fifo> -T <stats-fifo> --force-composition"
expect_env gamescope.env direct-no-drm-info "gamescope_drm_gbm_scanout=1"

# 7. Operator override of the mode: QUASAR_STEAM_DIRECT_ARGS replaces the
#    detected -W/-H/-r verbatim and detection is skipped.
run_launcher direct-override \
  QUASAR_DIRECT_DISPLAY=1 STUB_DRM_INFO="$T/fixtures/nvidia-4k240.json" \
  QUASAR_STEAM_DIRECT_ARGS="-W 1920 -H 1080 -r 60 -O DP-2"
expect_argv direct-override "--backend drm -e -R <ready-fifo> -T <stats-fifo> -W 1920 -H 1080 -r 60 -O DP-2 --force-composition"

# 8. Operator switch-off of the GBM workaround on NVIDIA.
run_launcher direct-gbm-off \
  QUASAR_DIRECT_DISPLAY=1 STUB_DRM_INFO="$T/fixtures/nvidia-4k240.json" QUASAR_STEAM_GBM_SCANOUT=0
expect_argv direct-gbm-off "--backend drm -e -R <ready-fifo> -T <stats-fifo> -W 3840 -H 2160 -r 240"
expect_env gamescope.env direct-gbm-off "gamescope_drm_gbm_scanout<unset>"

# 9. Direct display has no display server without gamescope, so the
#    no-gamescope knob cannot take it away.
run_launcher direct-gamescope-off \
  QUASAR_DIRECT_DISPLAY=1 STUB_DRM_INFO="$T/fixtures/amd-1440p165.json" QUASAR_STEAM_GAMESCOPE=0
expect_argv direct-gamescope-off "--backend drm -e -R <ready-fifo> -T <stats-fifo> -W 2560 -H 1440 -r 165"

# --- Steam UI-mode cases -------------------------------------------------------
# The preset's value is honoured verbatim (this is how the plain Steam app
# keeps Big Picture now that the image bakes in no default).
run_launcher preset-bigpicture STEAM_STARTUP_FLAGS=-bigpicture
expect_env client.env preset-bigpicture "STEAM_STARTUP_FLAGS=-bigpicture"
expect_no_launcher_log preset-bigpicture "$NO_UI_WARNING"

# STEAM_STARTUP_FLAGS overrides a QUASAR_STEAM_UI_MODE opt-in wholesale, and
# the STEAM_MULTIPLE_XWAYLANDS default follows the effective flags, so this
# is not a partial gamepadui unit.
run_launcher preset-overrides-mode STEAM_STARTUP_FLAGS=-bigpicture QUASAR_STEAM_UI_MODE=gamepadui
expect_env client.env preset-overrides-mode "STEAM_STARTUP_FLAGS=-bigpicture"
expect_launcher_log preset-overrides-mode "QUASAR_STEAM_UI_MODE=gamepadui ignored: STEAM_STARTUP_FLAGS is set"
expect_launcher_log preset-overrides-mode "multi_xwayland=0"
expect_no_launcher_log preset-overrides-mode "$NO_UI_WARNING"

# The gamepadui flag set carried as STEAM_STARTUP_FLAGS (how an app opts in
# when its preset already carries flags) gets Xwayland isolation.
run_launcher flags-gamepadui STEAM_STARTUP_FLAGS="-gamepadui -steamos3 -steampal -steamdeck"
expect_env client.env flags-gamepadui "STEAM_STARTUP_FLAGS=-gamepadui -steamos3 -steampal -steamdeck"
expect_launcher_log flags-gamepadui "multi_xwayland=1"
expect_no_launcher_log flags-gamepadui "$NO_UI_WARNING"

# A partial -gamepadui (not the full SteamOS unit) gets no Xwayland isolation.
run_launcher flags-gamepadui-partial STEAM_STARTUP_FLAGS="-gamepadui"
expect_env client.env flags-gamepadui-partial "STEAM_STARTUP_FLAGS=-gamepadui"
expect_launcher_log flags-gamepadui-partial "multi_xwayland=0"
expect_no_launcher_log flags-gamepadui-partial "$NO_UI_WARNING"

# -tenfoot is a UI-mode flag (legacy Big Picture switch): no warning.
run_launcher flags-tenfoot STEAM_STARTUP_FLAGS=-tenfoot
expect_env client.env flags-tenfoot "STEAM_STARTUP_FLAGS=-tenfoot"
expect_no_launcher_log flags-tenfoot "$NO_UI_WARNING"

# gamepadui opt-in unchanged: the full validated flag set as one unit, with
# per-game Xwayland isolation on.
run_launcher mode-gamepadui QUASAR_STEAM_UI_MODE=gamepadui
expect_env client.env mode-gamepadui "STEAM_STARTUP_FLAGS=-gamepadui -steamos3 -steampal -steamdeck"
expect_launcher_log mode-gamepadui "multi_xwayland=1"
expect_no_launcher_log mode-gamepadui "$NO_UI_WARNING"

# bigpicture as an explicit mode still gives -bigpicture.
run_launcher mode-bigpicture QUASAR_STEAM_UI_MODE=bigpicture
expect_env client.env mode-bigpicture "STEAM_STARTUP_FLAGS=-bigpicture"
expect_no_launcher_log mode-bigpicture "$NO_UI_WARNING"

# An unknown mode logs and gets no UI flag (and so also warns: no UI mode and
# no game to launch).
run_launcher mode-unknown QUASAR_STEAM_UI_MODE=bogus
expect_env client.env mode-unknown "STEAM_STARTUP_FLAGS="
expect_launcher_log mode-unknown "unknown QUASAR_STEAM_UI_MODE='bogus'; starting Steam with no UI-mode flag"
expect_launcher_log mode-unknown "$NO_UI_WARNING"

# A derived tile (-applaunch <id>) gets no warning: it is not the plain app.
run_launcher derived-applaunch STEAM_STARTUP_FLAGS="-applaunch 1234"
expect_env client.env derived-applaunch "STEAM_STARTUP_FLAGS=-applaunch 1234"
expect_no_launcher_log derived-applaunch "$NO_UI_WARNING"

# steam-wrapper with STEAM_STARTUP_FLAGS unset passes no argument to steam.sh
# (no -bigpicture fallback, and no empty argument either). The wrapper is
# installed as quasar-steam-client; a fake steam.sh records what it received.
run_wrapper() {
  local name="$1"; shift
  log="/tmp/cases/$name"
  rm -rf "$log" && mkdir -p "$log/home/.local/share/Steam"
  cat > "$log/home/.local/share/Steam/steam.sh" <<'EOF'
#!/usr/bin/env bash
printf 'argc=%s\n' "$#" > "$STUB_LOG/wrapper.args"
printf '%s\n' "$@" >> "$STUB_LOG/wrapper.args"
EOF
  chmod 0755 "$log/home/.local/share/Steam/steam.sh"
  # A Steam config.vdf the home already had (a fixture path), if the case sets one.
  if [[ -n "${seed_config:-}" ]]; then
    mkdir -p "$log/home/.local/share/Steam/config"
    cp "$seed_config" "$log/home/.local/share/Steam/config/config.vdf"
  fi
  # A Steam registry.vdf the home already had (a fixture path), if the case sets one.
  if [[ -n "${seed_registry:-}" ]]; then
    mkdir -p "$log/home/.steam"
    cp "$seed_registry" "$log/home/.steam/registry.vdf"
  fi
  # A config/ the app user cannot use (the cases run as root, which ignores file
  # modes, so the wrapper then runs as the app user): a file in its place, or a
  # directory that is not writable.
  local as=()
  if [[ -n "${config_as_file:-}" ]]; then
    : > "$log/home/.local/share/Steam/config"
  elif [[ -n "${config_readonly:-}" ]]; then
    mkdir -p "$log/home/.local/share/Steam/config"
    chmod 0555 "$log/home/.local/share/Steam/config"
  fi
  if [[ -n "${config_as_file:-}${config_readonly:-}" ]]; then
    chmod 0777 "$log" "$log/home"
    as=(setpriv --reuid=1000 --regid=1000 --clear-groups)
  fi
  local rc=0
  env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="$log/home" STUB_LOG="$log" \
    "$@" timeout 30 "${as[@]}" /usr/local/bin/quasar-steam-client >"$log/wrapper.out" 2>&1 || rc=$?
  if [[ "$rc" != 0 ]]; then
    fail "$name: steam-wrapper exited $rc"
    sed 's/^/      /' "$log/wrapper.out" >&2
  fi
  return 0
}

run_wrapper wrapper-unset
if [[ "$(cat "$log/wrapper.args" 2>/dev/null)" == "argc=0" ]]; then
  pass "wrapper-unset: steam.sh received no arguments"
else
  fail "wrapper-unset: steam.sh received: $(paste -sd' ' "$log/wrapper.args" 2>/dev/null)"
fi

run_wrapper wrapper-bigpicture STEAM_STARTUP_FLAGS=-bigpicture
if [[ "$(paste -sd' ' "$log/wrapper.args" 2>/dev/null)" == "argc=1 -bigpicture" ]]; then
  pass "wrapper-bigpicture: steam.sh received -bigpicture"
else
  fail "wrapper-bigpicture: steam.sh received: $(paste -sd' ' "$log/wrapper.args" 2>/dev/null)"
fi

# Steam's idle screensaver is off unless the home already carries a choice
# (accreleus/quasar#819): the wrapper writes IdleScreensaverACSeconds=0 into
# config.vdf's Steam/system block before Steam starts, and nothing else changes.
# The config files are golden: the inputs have a decoy "system" block at the
# wrong path, which must not be the one edited.
expect_config() { # <case> <expected file>
  local got="$log/home/.local/share/Steam/config/config.vdf"
  if [[ "$(cat "$got")" == "$(cat "$2")" ]]; then
    pass "$1: config.vdf is as expected"
  else
    fail "$1: config.vdf differs from $(basename "$2"); it is:"
    sed 's/^/      /' "$got" >&2
  fi
  if compgen -G "$log/home/.local/share/Steam/config/.config.vdf.*" >/dev/null; then
    fail "$1: a temp file was left in config/"
  fi
}
seed_config="" run_wrapper screensaver-fresh
expect_config screensaver-fresh "$T/fixtures/config-fresh.out.vdf"
seed_config="$T/fixtures/config-system.in.vdf" run_wrapper screensaver-system
expect_config screensaver-system "$T/fixtures/config-system.out.vdf"
seed_config="$T/fixtures/config-nosystem.in.vdf" run_wrapper screensaver-nosystem
expect_config screensaver-nosystem "$T/fixtures/config-nosystem.out.vdf"
# A value already there (the user chose one in Steam) is theirs.
seed_config="$T/fixtures/config-choice.vdf" run_wrapper screensaver-choice
expect_config screensaver-choice "$T/fixtures/config-choice.vdf"
# Not a config Steam wrote: no Steam block to put the key in, so the file is left alone.
seed_config="$T/fixtures/config-nosteam.vdf" run_wrapper screensaver-nosteam
expect_config screensaver-nosteam "$T/fixtures/config-nosteam.vdf"
# A CRLF file is edited too, and keeps its line endings.
seed_config="$T/fixtures/config-crlf.in.vdf" run_wrapper screensaver-crlf
expect_config screensaver-crlf "$T/fixtures/config-crlf.out.vdf"
# A failed edit never fails the launch: with a config/ the app user cannot use
# (a file in its place; a directory it cannot write) Steam still starts.
config_as_file=1 run_wrapper screensaver-config-is-file
if [[ "$(head -1 "$log/wrapper.args" 2>/dev/null)" == "argc=0" ]]; then
  pass "screensaver-config-is-file: steam.sh still started"
else
  fail "screensaver-config-is-file: steam.sh was not started"
fi
config_readonly=1 run_wrapper screensaver-config-readonly
if [[ "$(head -1 "$log/wrapper.args" 2>/dev/null)" == "argc=0" ]]; then
  pass "screensaver-config-readonly: steam.sh still started"
else
  fail "screensaver-config-readonly: steam.sh was not started"
fi
if grep -q "starting Steam anyway" "$log/wrapper.out"; then
  pass "screensaver-config-readonly: one warning, then Steam started"
else
  fail "screensaver-config-readonly: no warning in the wrapper's output"
fi
# Steam does not follow LANG (accreleus/quasar#848), so a home with no Steam language yet
# starts with `-language <name>` for the launch's LANG, once. A home that already has one is
# the user's, an explicit -language wins, and English or an unmapped language gets no flag.
expect_steam_args() { # <case> <want: the argc line and args, space-joined>
  local got; got="$(paste -sd' ' "$log/wrapper.args" 2>/dev/null | sed 's/ *$//')"
  if [[ "$got" == "$2" ]]; then pass "$1: steam.sh received '$2'"; else fail "$1: steam.sh received '$got', want '$2'"; fi
}
run_wrapper lang-fresh LANG=de_DE.UTF-8
expect_steam_args lang-fresh "argc=2 -language german"
run_wrapper lang-with-ui-flag LANG=de_DE.UTF-8 STEAM_STARTUP_FLAGS=-bigpicture
expect_steam_args lang-with-ui-flag "argc=3 -bigpicture -language german"
seed_registry="$T/fixtures/registry-nolanguage.vdf" run_wrapper lang-registry-no-key LANG=ja_JP.UTF-8
expect_steam_args lang-registry-no-key "argc=2 -language japanese"
# A home that has a language (Steam wrote it, or the user chose it) keeps it.
seed_registry="$T/fixtures/registry-english.vdf" run_wrapper lang-existing-english LANG=de_DE.UTF-8
expect_steam_args lang-existing-english "argc=0"
run_wrapper lang-explicit LANG=de_DE.UTF-8 STEAM_STARTUP_FLAGS="-language french"
expect_steam_args lang-explicit "argc=2 -language french"
for unmapped in en_US.UTF-8 en_GB.UTF-8 cs_CZ.UTF-8 C.UTF-8 POSIX C ""; do
  run_wrapper "lang-unmapped-${unmapped:-empty}" LANG="$unmapped"
  expect_steam_args "lang-unmapped-${unmapped:-empty}" "argc=0"
done
run_wrapper lang-unset
expect_steam_args lang-unset "argc=0"
# The names: Steam's API language codes, for the languages the quasar settings offer.
for pair in de_DE:german fr_FR:french es_ES:spanish it_IT:italian nl_NL:dutch pl_PL:polish pt_BR:brazilian \
            sv_SE:swedish ru_RU:russian ja_JP:japanese ko_KR:koreana zh_CN:schinese \
            es_MX:latam pt_PT:portuguese zh_TW:tchinese de_AT:german; do
  run_wrapper "lang-map-${pair%%:*}" "LANG=${pair%%:*}.UTF-8"
  expect_steam_args "lang-map-${pair%%:*}" "argc=2 -language ${pair#*:}"
done
# --- init hook cases -----------------------------------------------------------

SEATD_HOOK=/etc/quasar/init.d/25-steam-direct-seatd.sh
GROUPS_HOOK=/etc/quasar/init.d/24-steam-direct-device-groups.sh
for hook in "$SEATD_HOOK" "$GROUPS_HOOK"; do
  if [[ -x "$hook" ]]; then pass "hook present: $hook"; else fail "hook missing or not executable: $hook"; fi
done

# 10. seatd hook, nested: nothing started, no socket.
rm -f /run/seatd.sock
if [[ -x "$SEATD_HOOK" ]] && env -i PATH=/usr/local/bin:/usr/bin:/bin PUID=1000 PGID=1000 "$SEATD_HOOK"; then
  if pgrep -x seatd >/dev/null || [[ -e /run/seatd.sock ]]; then
    fail "seatd-nested: seatd started without QUASAR_DIRECT_DISPLAY=1"
  else
    pass "seatd-nested: no seatd"
  fi
else
  fail "seatd-nested: hook failed"
fi

# 11. seatd hook, direct: the real seatd, not VT-bound, its socket owned by the
#     app user and group (by NAME -- seatd 0.9.3 takes names, not ids). A stale
#     socket from a previous run of the container must not satisfy the wait.
: > /run/seatd.sock
if [[ -x "$SEATD_HOOK" ]] && env -i PATH=/usr/local/bin:/usr/bin:/bin PUID=1000 PGID=1000 QUASAR_DIRECT_DISPLAY=1 "$SEATD_HOOK"; then
  pid="$(pgrep -x seatd || true)"
  if [[ -z "$pid" ]]; then
    fail "seatd-direct: seatd is not running"
  else
    args="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
    [[ "$args" == *"-u $APP_USER "* && "$args" == *"-g $APP_GROUP"* ]] \
      && pass "seatd-direct: seatd $args" || fail "seatd-direct: seatd args are '$args'"
    tr '\0' '\n' < "/proc/$pid/environ" | grep -qx 'SEATD_VTBOUND=0' \
      && pass "seatd-direct: SEATD_VTBOUND=0" || fail "seatd-direct: SEATD_VTBOUND=0 not in seatd's environment"
  fi
  if [[ -S /run/seatd.sock ]] && [[ "$(stat -c %U:%G /run/seatd.sock)" == "$APP_USER:$APP_GROUP" ]]; then
    pass "seatd-direct: /run/seatd.sock is a socket owned by $APP_USER:$APP_GROUP"
  else
    fail "seatd-direct: /run/seatd.sock is $(stat -c '%F %U:%G' /run/seatd.sock 2>&1)"
  fi
  # Running the hook again (a container restart re-runs the init chain) must
  # not start a second daemon.
  env -i PATH=/usr/local/bin:/usr/bin:/bin PUID=1000 PGID=1000 QUASAR_DIRECT_DISPLAY=1 "$SEATD_HOOK" || fail "seatd-direct: second run failed"
  [[ "$(pgrep -cx seatd)" == 1 ]] && pass "seatd-direct: one daemon after a re-run" || fail "seatd-direct: $(pgrep -cx seatd) seatd processes after a re-run"
  pkill -x seatd || true
else
  fail "seatd-direct: hook failed"
fi

# 12. Device groups: in direct mode the app user joins the groups owning
#     /dev/input/event* and /dev/hidraw* (Steam Input reads physical controllers
#     itself; gamescope's own devices still come from seatd) and /dev/snd (sound
#     on the console's card). Never gid 0 or 65534, nothing for a world-rw node,
#     and nothing at all in a nested session.
mkdir -p /dev/snd /dev/input
mknod_node() { rm -f "$1"; mknod "$1" c "$2" "$3"; chgrp "$4" "$1"; chmod "${5:-0660}" "$1"; }
mknod_node /dev/snd/controlC0 116 0 4301
mknod_node /dev/snd/pcmC0D0p 116 16 0
mknod_node /dev/input/event7 13 71 4302
mknod_node /dev/hidraw3 240 3 4304
mknod_node /dev/input/event8 13 72 65534
mknod_node /dev/input/event9 13 73 4305 0666
in_group() { id -G "$APP_USER" | tr ' ' '\n' | grep -qx "$1"; }

if [[ -x "$GROUPS_HOOK" ]] && env -i PATH=/usr/local/bin:/usr/bin:/bin PUID=1000 PGID=1000 "$GROUPS_HOOK"; then
  if in_group 4301 || in_group 4302 || in_group 4304; then fail "groups-nested: joined a device group without direct display"; else pass "groups-nested: no membership"; fi
else
  fail "groups-nested: hook failed"
fi
if [[ -x "$GROUPS_HOOK" ]] && env -i PATH=/usr/local/bin:/usr/bin:/bin PUID=1000 PGID=1000 QUASAR_DIRECT_DISPLAY=1 "$GROUPS_HOOK"; then
  in_group 4301 && pass "groups-direct: joined the /dev/snd group (gid 4301)" || fail "groups-direct: not a member of gid 4301 (/dev/snd)"
  in_group 4302 && pass "groups-direct: joined the /dev/input group (gid 4302)" || fail "groups-direct: not a member of gid 4302 (/dev/input)"
  in_group 4304 && pass "groups-direct: joined the /dev/hidraw group (gid 4304)" || fail "groups-direct: not a member of gid 4304 (/dev/hidraw)"
  in_group 0 && fail "groups-direct: granted gid 0" || pass "groups-direct: gid 0 never granted"
  in_group 65534 && fail "groups-direct: granted gid 65534" || pass "groups-direct: gid 65534 never granted"
  in_group 4305 && fail "groups-direct: joined the group of a world-rw node" || pass "groups-direct: world-rw node skipped"
else
  fail "groups-direct: hook failed"
fi
rm -f /dev/hidraw3 /dev/input/event8 /dev/input/event9

# 13. Direct display bind-mounts the HOST's /dev/input, so no init hook may
#     change anything under it: not a mode, an owner, a group, or a node. The
#     whole inherited chain runs (quasar-base, quasar-steam-runtime, this image)
#     as quasar-entrypoint runs it, against a joystick node that 15- WOULD open
#     up in a nested session, with every chmod/chown/chgrp/mknod/setfacl/rm/mv
#     recorded on the way. The nested run is the control: it must touch the node,
#     or this case could not see a change at all.
SHIMS=/tmp/devshims
mkdir -p "$SHIMS"
for tool in chmod chown chgrp mknod setfacl rm mv ln install; do
  real="$(command -v "$tool" || true)"
  [[ -n "$real" ]] || continue
  printf '#!/bin/bash\nprintf "%%s %%s\\n" %q "$*" >> /tmp/devshims.log\nexec %q "$@"\n' "$tool" "$real" > "$SHIMS/$tool"
  chmod 0755 "$SHIMS/$tool"
done
pad_minor=77
pad=/dev/input/event$((pad_minor - 64))
mknod_node "$pad" 13 "$pad_minor" 4303
mkdir -p /run/udev/data
printf 'E:ID_INPUT=1\nE:ID_INPUT_JOYSTICK=1\n' > "/run/udev/data/c13:$pad_minor"
# Numeric owner/group: a hook may legitimately NAME a host gid in the
# container's /etc/group (that is how membership works), which changes %g but
# not the node.
snapshot_input() { find /dev/input -mindepth 1 -printf '%p %y %m %U:%G %Y\n' | sort; }

run_init_chain() {
  : > /tmp/devshims.log
  local hook
  for hook in /etc/quasar/init.d/*.sh; do
    [[ -x "$hook" ]] || continue
    env -i PATH="$SHIMS:/usr/local/bin:/usr/bin:/bin" PUID=1000 PGID=1000 \
      QUASAR_STEAM_SYSTEM_SERVICES=0 "$@" "$hook" >/dev/null 2>&1 \
      || fail "init-chain($*): $(basename "$hook") failed"
  done
  pkill -x seatd 2>/dev/null || true
}

before="$(snapshot_input)"
run_init_chain QUASAR_DIRECT_DISPLAY=1
after="$(snapshot_input)"
if [[ "$before" == "$after" ]]; then
  pass "init-chain(direct): /dev/input unchanged"
else
  fail "init-chain(direct): /dev/input changed"
  printf '      before: %s\n' "$before" >&2
  printf '      after:  %s\n' "$after" >&2
fi
if grep -q '/dev/input' /tmp/devshims.log; then
  fail "init-chain(direct): a hook ran a file-changing command on /dev/input: $(grep '/dev/input' /tmp/devshims.log | paste -sd';')"
else
  pass "init-chain(direct): no chmod/chown/chgrp/mknod/setfacl/rm/mv on /dev/input"
fi

run_init_chain
if [[ "$(stat -c %a "$pad")" == 666 ]] && grep -q "chmod 0666 $pad" /tmp/devshims.log; then
  pass "init-chain(nested control): 15-input-device-perms.sh still opens the gamepad node"
else
  fail "init-chain(nested control): gamepad node is $(stat -c %a "$pad"); the case cannot detect a change"
fi

if (( failures )); then
  printf '%s launcher/hook case(s) failed\n' "$failures" >&2
  exit 1
fi
echo "quasar-steam launcher and direct-display hook cases passed"
