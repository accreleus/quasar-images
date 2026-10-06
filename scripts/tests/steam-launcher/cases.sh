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
#     the nested parent (its socket, the stream mode, the mode-forward Xwayland)
#     leaks in.
#   * the seatd and sound-group hooks act only in direct mode.
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
  : > "$log/gamescope.args"; : > "$log/gamescope.env"; : > "$log/client.env"
  local rc=0
  env -i PATH="$T/stubs:/usr/local/bin:/usr/bin:/bin" HOME="$log/home" STUB_LOG="$log" \
    "$@" timeout 60 "$LAUNCHER" >"$log/launcher.out" 2>&1 || rc=$?
  # The gamescope stub idles like a compositor; the launcher does not kill it
  # on a clean Steam exit (nor does it in production -- the container exits).
  pkill -f "^sleep 300$" 2>/dev/null || true
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

# 1. Nested: today's command line, byte for byte, and no direct-display state.
run_launcher nested \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 \
  QUASAR_STREAM_WIDTH=2560 QUASAR_STREAM_HEIGHT=1440 QUASAR_STREAM_FPS=120
expect_argv nested "-e -b -R <ready-fifo> -T <stats-fifo> -W 2560 -H 1440 -r 120"
expect_env gamescope.env nested "WAYLAND_DISPLAY=/run/quasar-wayland/wayland-3"
expect_env gamescope.env nested "WLR_XWAYLAND=/usr/local/libexec/quasar-steam/Xwayland"
expect_env gamescope.env nested "gamescope_drm_gbm_scanout<unset>"
expect_env gamescope.env nested "LIBSEAT_BACKEND<unset>"
expect_env client.env nested "DISPLAY=:7"
expect_env client.env nested "WAYLAND_DISPLAY<unset>"
if drm_info_called; then fail "nested: drm_info must not be consulted"; else pass "nested: drm_info not consulted"; fi

# 1b. Nested with anything other than exactly "1" stays nested.
run_launcher nested-not-one \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 QUASAR_DIRECT_DISPLAY=true
expect_argv nested-not-one "-e -b -R <ready-fifo> -T <stats-fifo> -W 1920 -H 1080 -r 60"
expect_env gamescope.env nested-not-one "gamescope_drm_gbm_scanout<unset>"

# 2. Direct on the console host's shape: NVIDIA, one 4K panel whose preferred
#    mode is 60 Hz and whose best mode at that size is 240 Hz. The agent may
#    still hand over a parent socket and a stream mode; both must be ignored.
run_launcher direct-nvidia \
  QUASAR_DIRECT_DISPLAY=1 STUB_DRM_INFO="$T/fixtures/nvidia-4k240.json" \
  XDG_RUNTIME_DIR=/run/quasar-wayland WAYLAND_DISPLAY=wayland-3 DISPLAY=:99 \
  QUASAR_STREAM_WIDTH=1920 QUASAR_STREAM_HEIGHT=1080 QUASAR_STREAM_FPS=60
expect_argv direct-nvidia "--backend drm -e -R <ready-fifo> -T <stats-fifo> -W 3840 -H 2160 -r 240 --force-composition"
expect_env gamescope.env direct-nvidia "gamescope_drm_gbm_scanout=1"
expect_env gamescope.env direct-nvidia "LIBSEAT_BACKEND=seatd"
expect_env gamescope.env direct-nvidia "WAYLAND_DISPLAY<unset>"
expect_env gamescope.env direct-nvidia "DISPLAY<unset>"
expect_env gamescope.env direct-nvidia "WLR_XWAYLAND<unset>"
expect_env client.env direct-nvidia "DISPLAY=:7"
expect_env client.env direct-nvidia "WAYLAND_DISPLAY<unset>"
expect_env client.env direct-nvidia "STEAM_STARTUP_FLAGS=-bigpicture"
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

# --- init hook cases -----------------------------------------------------------

SEATD_HOOK=/etc/quasar/init.d/25-steam-direct-seatd.sh
SOUND_HOOK=/etc/quasar/init.d/24-steam-direct-sound-groups.sh
for hook in "$SEATD_HOOK" "$SOUND_HOOK"; do
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

# 12. Sound groups: in direct mode the app user joins the group owning each
#     /dev/snd node (it plays to the real card); never gid 0; and NOT the
#     /dev/input groups -- gamescope gets input devices from seatd, and an app
#     that can open keyboard/mouse nodes itself can EVIOCGRAB them away from it.
mkdir -p /dev/snd /dev/input
mknod_node() { rm -f "$1"; mknod "$1" c "$2" "$3"; chgrp "$4" "$1"; chmod 0660 "$1"; }
mknod_node /dev/snd/controlC0 116 0 4301
mknod_node /dev/snd/pcmC0D0p 116 16 0
mknod_node /dev/input/event7 13 71 4302
in_group() { id -G "$APP_USER" | tr ' ' '\n' | grep -qx "$1"; }

if [[ -x "$SOUND_HOOK" ]] && env -i PATH=/usr/local/bin:/usr/bin:/bin PUID=1000 PGID=1000 "$SOUND_HOOK"; then
  in_group 4301 && fail "sound-nested: joined gid 4301 without direct display" || pass "sound-nested: no membership"
else
  fail "sound-nested: hook failed"
fi
if [[ -x "$SOUND_HOOK" ]] && env -i PATH=/usr/local/bin:/usr/bin:/bin PUID=1000 PGID=1000 QUASAR_DIRECT_DISPLAY=1 "$SOUND_HOOK"; then
  in_group 4301 && pass "sound-direct: joined the /dev/snd group (gid 4301)" || fail "sound-direct: not a member of gid 4301"
  in_group 0 && fail "sound-direct: granted gid 0" || pass "sound-direct: gid 0 never granted"
  in_group 4302 && fail "sound-direct: joined the /dev/input group" || pass "sound-direct: /dev/input group left to seatd"
else
  fail "sound-direct: hook failed"
fi

if (( failures )); then
  printf '%s launcher/hook case(s) failed\n' "$failures" >&2
  exit 1
fi
echo "quasar-steam launcher and direct-display hook cases passed"
