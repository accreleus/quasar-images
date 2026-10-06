#!/usr/bin/env bash
# verify-kde-launcher.sh -- behavioural tests of quasar-kde's two entries.
#
# The launcher has two entries, chosen by one variable the node agent sets
# (quasar#453):
#
#   QUASAR_DIRECT_DISPLAY=1      direct: Plasma on KWin's DRM backend, the
#                                desktop owns the monitor. No parent socket.
#   unset, or any other value    nested: today's streamed session, KWin as a
#                                Wayland client of the agent's compositor.
#
# These tests run the image's REAL entrypoint and init hooks and the REAL
# launcher, with the session programs (dbus-run-session, startplasma-wayland,
# the PipeWire daemons, flatpak) replaced by recording stubs on PATH. What is
# asserted is what the session would observe: its environment, its groups, its
# runtime directory, which daemons were started, and the nodes the hooks left
# alone. Nothing here needs a GPU, a monitor or a sound card: the input and
# sound nodes are made with mknod inside the container.
#
#   ./scripts/verify-kde-launcher.sh             test quasar-kde:$QUASAR_IMAGE_TAG
#   ./scripts/verify-kde-launcher.sh --source    same image, but with this tree's
#                                                launcher, helper and hooks
#                                                mounted over it: iterate on a
#                                                launcher edit without a rebuild.
#                                                The gate never uses it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# shellcheck source=scripts/lib/verify-lib.sh
. "$root/scripts/lib/verify-lib.sh"
qv_init

TAG="${QUASAR_IMAGE_TAG:-dev}"
KDE_IMAGE="${QUASAR_KDE_IMAGE:-quasar-kde:$TAG}"

mounts=()
if [[ "${1:-}" == --source ]]; then
  mounts=(
    -v "$root/images/quasar-kde/quasar-kde:/usr/local/bin/quasar-kde:ro"
    -v "$root/images/quasar-kde/direct-session:/usr/local/libexec/quasar-kde/direct-session:ro"
  )
  for hook in overlay/etc/quasar/init.d/*.sh images/quasar-kde/overlay/etc/quasar/init.d/*.sh; do
    mounts+=(-v "$root/$hook:/etc/quasar/init.d/$(basename "$hook"):ro")
  done
  echo "testing $KDE_IMAGE with the launcher, helper and hooks from this tree"
else
  echo "testing the launcher in $KDE_IMAGE"
fi

# --- the in-container harness ------------------------------------------------
# Runs as root BEFORE the entrypoint, so it can lay down stubs and device
# nodes, then hands over to the real quasar-entrypoint exactly as the image's
# own ENTRYPOINT would. Every record is printed as "@@ <name>" sections.
#
# Fake nodes (the gids are deliberately ones no Fedora group uses):
#   /dev/input/event77  c 13:141  root:4242 0660   a keyboard
#   /dev/input/event78  c 13:142  root:4242 0660   a joystick (udev record says so)
#   /dev/snd/controlC7  c 116:7   root:4343 0660   a sound card
#   /dev/snd/seq        c 116:1   root:root 0660   gid 0: never granted
# shellcheck disable=SC2016  # expands in the container's shell
harness='set -euo pipefail
out=/tmp/qv-out stubs=/opt/qv-stubs
mkdir -p "$out" "$stubs" && chmod 0777 "$out"

record() {  # record <name> [extra command] -- argv + env of the caller
  cat <<EOF
#!/usr/bin/env bash
printf "%s\n" "\$@" > $out/$1.argv
env | sort > $out/$1.env
EOF
}
{ record dbus-run-session
  echo "[[ \"\${1:-}\" == -- ]] && shift"
  echo "export QV_IN_SESSION_BUS=1"
  echo "exec \"\$@\""; } > "$stubs/dbus-run-session"
{ record startplasma-wayland
  echo "stat -c \"%a %U\" \"\$XDG_RUNTIME_DIR\" > $out/runtime-dir"
  echo "stat -c \"%a\" /tmp/.X11-unix > $out/x11-dir"
  echo "id -G | tr \" \" \"\\n\" | sort -n > $out/groups"; } > "$stubs/startplasma-wayland"
{ record pipewire
  echo "touch \"\$XDG_RUNTIME_DIR/pipewire-0\""; } > "$stubs/pipewire"
record wireplumber > "$stubs/wireplumber"
record pipewire-pulse > "$stubs/pipewire-pulse"
printf "#!/bin/sh\nexit 0\n" > "$stubs/flatpak"
chmod 0755 "$stubs"/*

mkdir -p /dev/input /dev/snd /run/udev/data
mknod -m 0660 /dev/input/event77 c 13 141 && chgrp 4242 /dev/input/event77
mknod -m 0660 /dev/input/event78 c 13 142 && chgrp 4242 /dev/input/event78
printf "E:ID_INPUT=1\nE:ID_INPUT_JOYSTICK=1\n" > /run/udev/data/c13:142
mknod -m 0660 /dev/snd/controlC7 c 116 7 && chgrp 4343 /dev/snd/controlC7
mknod -m 0660 /dev/snd/seq c 116 1

if [[ -n "${QV_PARENT_SOCKET:-}" ]]; then
  mkdir -p /run/quasar-wayland && touch "/run/quasar-wayland/$QV_PARENT_SOCKET"
fi

export PATH="$stubs:$PATH"
/usr/local/bin/quasar-entrypoint bash -c "
  if quasar-kde; then rc=0; else rc=\$?; fi
  sleep 1
  echo \"@@ rc\"; echo \"\$rc\"
  for f in $out/*; do echo \"@@ \$(basename \"\$f\")\"; cat \"\$f\"; done
  echo \"@@ joystick-mode\"; stat -c %a /dev/input/event78
" 2>/tmp/qv-stderr || true
echo "@@ stderr"; cat /tmp/qv-stderr
'

# run_case <name> [docker -e args...] -- prints the harness output
run_case() {
  local name="$1"; shift
  docker run --rm "${mounts[@]}" \
    -e QUASAR_GPU_PROBE_ON_STARTUP=0 -e QUASAR_STEAM_SYSTEM_SERVICES=0 \
    "$@" --entrypoint /bin/bash "$KDE_IMAGE" -c "$harness" 2>&1 \
    || { echo "FAIL: case '$name' did not run" >&2; exit 1; }
}

section() { awk -v s="@@ $2" '$0 == s {f = 1; next} /^@@ / {f = 0} f' <<<"$1"; }

# expect <output> <section> <exact line> <why>
expect() {
  if ! section "$1" "$2" | grep -qxF -- "$3"; then
    printf 'FAIL: [%s] %s has no line "%s"\n      %s\n' "$case" "$2" "$3" "$4" >&2
    dump "$1"; exit 1
  fi
}
# expect_not <output> <section> <ERE> <why>
expect_not() {
  local hit
  if hit="$(section "$1" "$2" | grep -E -- "$3")"; then
    printf 'FAIL: [%s] %s has "%s"\n      %s\n' "$case" "$2" "$hit" "$4" >&2
    dump "$1"; exit 1
  fi
}
# expect_absent <output> <section> <why>
expect_absent() {
  if grep -qxF "@@ $2" <<<"$1"; then
    printf 'FAIL: [%s] %s was recorded\n      %s\n' "$case" "$2" "$3" >&2
    dump "$1"; exit 1
  fi
}
dump() { printf '%s\n' "--- harness output ---" "$1" >&2; }

# --- direct entry ------------------------------------------------------------
# Leftovers a streamed session's variables could carry (a parent socket name, an
# X display, the agent's Pulse sink) are set on purpose: the direct entry must
# drop every one of them, and there is NO parent socket file at all.
case=direct
o="$(run_case direct -e QUASAR_DIRECT_DISPLAY=1 \
  -e XDG_RUNTIME_DIR=/run/quasar-wayland -e WAYLAND_DISPLAY=wayland-qv -e DISPLAY=:9 \
  -e PULSE_SERVER=unix:/run/quasar-pulse/native -e PULSE_SINK=quasar -e PULSE_COOKIE=/run/quasar-pulse/cookie)"

expect "$o" rc 0 "the direct entry must start without any parent compositor socket"
expect "$o" startplasma-wayland.env QV_IN_SESSION_BUS=1 \
  "Plasma must be started inside dbus-run-session (one session bus for the desktop)"
expect_not "$o" startplasma-wayland.argv . "startplasma-wayland takes no arguments"
expect_not "$o" startplasma-wayland.env '^(WAYLAND_DISPLAY|DISPLAY)=' \
  "with a parent socket or X display set, KWin starts NESTED instead of on DRM"
expect "$o" startplasma-wayland.env XDG_RUNTIME_DIR=/home/quasar/.runtime \
  "KWin and Plasma need a private runtime directory"
expect "$o" runtime-dir "700 quasar" "the runtime directory must be the app user's, 0700"
expect "$o" x11-dir 1777 "Xwayland needs /tmp/.X11-unix or the Plasma start-up stalls"
expect "$o" startplasma-wayland.env XDG_SESSION_TYPE=wayland "session type"
expect "$o" startplasma-wayland.env XDG_CURRENT_DESKTOP=KDE "desktop name"
expect "$o" startplasma-wayland.env DESKTOP_SESSION=plasma "session name"
expect_not "$o" startplasma-wayland.env '^KWIN_USE_OVERLAYS=' \
  "the nested black-stream fix must not reach KWin on DRM, where overlays are hardware planes"
expect_not "$o" startplasma-wayland.env '^PATH=.*/usr/local/libexec/quasar-kde' \
  "the nested sizing shim would force windowed-mode --width/--height onto KWin"
expect_not "$o" startplasma-wayland.env '^QUASAR_KDE_OUTPUT_(WIDTH|HEIGHT)=' \
  "the nested output size has no meaning on DRM: KWin takes the monitor's mode"
expect_not "$o" startplasma-wayland.env '^PULSE_(SERVER|SINK|SOURCE|COOKIE)=' \
  "the desktop's own audio stack picks the output, not the agent's Pulse sink"
expect_not "$o" startplasma-wayland.env '^QT_LOGGING_RULES=.*kscreen\.kded' \
  "the nested mode-forwarding log rules are for the console mode-forward path"
for daemon in pipewire wireplumber pipewire-pulse; do
  expect "$o" "$daemon.env" QV_IN_SESSION_BUS=1 "$daemon must run inside the desktop's session bus"
  expect "$o" "$daemon.env" XDG_RUNTIME_DIR=/home/quasar/.runtime \
    "$daemon must put its socket where Plasma looks for it"
done
expect "$o" groups 4242 "the app user must join the group owning the input nodes"
expect "$o" groups 4343 "the app user must join the group owning the sound nodes"
expect_not "$o" groups '^0$' "gid 0 is never granted"
expect "$o" joystick-mode 660 \
  "the input directory is the host's own in direct mode; no hook may chmod its nodes"
qv_pass "direct entry: Plasma on its own session, no parent socket, audio daemons, device groups"

# --- nested entry: unchanged -------------------------------------------------
case=nested
o="$(run_case nested -e QV_PARENT_SOCKET=wayland-qv \
  -e XDG_RUNTIME_DIR=/run/quasar-wayland -e WAYLAND_DISPLAY=wayland-qv \
  -e QUASAR_STREAM_WIDTH=2560 -e QUASAR_STREAM_HEIGHT=1440 \
  -e PULSE_SERVER=unix:/run/quasar-pulse/native)"

expect "$o" rc 0 "the nested entry must start with the parent socket present"
[[ "$(section "$o" dbus-run-session.argv)" == $'--\nstartplasma-wayland' ]] \
  || { echo "FAIL: [nested] the session command line moved from 'dbus-run-session -- startplasma-wayland'" >&2; dump "$o"; exit 1; }
expect "$o" startplasma-wayland.env WAYLAND_DISPLAY=/run/quasar-wayland/wayland-qv \
  "nested KWin connects to the parent compositor through an absolute socket path"
expect "$o" startplasma-wayland.env XDG_RUNTIME_DIR=/home/quasar/.runtime "private runtime dir"
expect "$o" startplasma-wayland.env KWIN_USE_OVERLAYS=0 "the black-stream fix"
expect "$o" startplasma-wayland.env QUASAR_KDE_OUTPUT_WIDTH=2560 "the streamed mode sizes nested KWin"
expect "$o" startplasma-wayland.env QUASAR_KDE_OUTPUT_HEIGHT=1440 "the streamed mode sizes nested KWin"
expect "$o" startplasma-wayland.env \
  "QT_LOGGING_RULES=kwin_wayland_backend.info=true;kscreen.kded.debug=true;kscreen.kcm.debug=true" \
  "the nested logging rules"
expect "$o" startplasma-wayland.env PULSE_SERVER=unix:/run/quasar-pulse/native \
  "a streamed session's audio goes to the agent's Pulse sink"
if ! section "$o" startplasma-wayland.env | grep -qE '^PATH=/usr/local/libexec/quasar-kde:'; then
  echo "FAIL: [nested] the kwin sizing shim is not first on PATH" >&2; dump "$o"; exit 1
fi
for daemon in pipewire wireplumber pipewire-pulse; do
  expect_absent "$o" "$daemon.env" "a streamed session must not start its own $daemon"
done
expect_not "$o" groups '^(4242|4343)$' \
  "a streamed session must not join the input group: it could grab the virtual keyboard and mouse"
expect "$o" joystick-mode 666 "the streamed-session gamepad rule (15-input-device-perms.sh) is unchanged"
qv_pass "nested entry: unchanged"

# --- anything but exactly 1 is nested ----------------------------------------
for value in 0 true yes; do
  case="value-$value"
  o="$(run_case "$case" -e QUASAR_DIRECT_DISPLAY="$value")"
  expect "$o" rc 1 "QUASAR_DIRECT_DISPLAY=$value must take the nested entry, which needs a parent socket"
  if ! section "$o" stderr | grep -q 'FATAL: WAYLAND_DISPLAY is not set'; then
    echo "FAIL: [$case] the nested entry did not refuse the missing parent socket" >&2; dump "$o"; exit 1
  fi
  expect_absent "$o" startplasma-wayland.env "no session may start"
done
qv_pass "QUASAR_DIRECT_DISPLAY other than 1 (0, true, yes) takes the nested entry"

# --- the direct-mode device-group hook, edge cases ---------------------------
# The cases above prove the grant end to end; this pins the refusals: never gid
# 0, never the unmapped (rootless) gid, no group for a world-rw node, nothing at
# all unless the value is exactly 1. Node permissions are never changed.
docker run --rm "${mounts[@]}" --entrypoint /bin/bash "$KDE_IMAGE" -c "$QV_GUARD"'
  set -euo pipefail
  mkdir -p /dev/input /dev/snd
  mknod -m 0660 /dev/input/event20 c 13 84  && chgrp 4242  /dev/input/event20
  mknod -m 0660 /dev/input/event22 c 13 86  && chgrp 65534 /dev/input/event22
  mknod -m 0660 /dev/snd/controlC0 c 116 0  && chgrp 4343  /dev/snd/controlC0
  mknod -m 0660 /dev/snd/seq       c 116 1
  mknod -m 0666 /dev/snd/timer     c 116 33 && chgrp 4444  /dev/snd/timer
  useradd -u 1000 -M quasar 2>/dev/null || true
  hook=/etc/quasar/init.d/16-kde-direct-device-groups.sh
  test -x "$hook"
  modes_before="$(stat -c "%n %a %g" /dev/input/* /dev/snd/*)"

  for value in "" 0 true yes; do
    QUASAR_DIRECT_DISPLAY="$value" "$hook"
    if id -G quasar | tr " " "\n" | grep -qxE "4242|4343"; then
      echo "FAIL: QUASAR_DIRECT_DISPLAY=\"$value\" granted input/sound groups" >&2; exit 1
    fi
  done

  QUASAR_DIRECT_DISPLAY=1 "$hook" 2>/dev/null
  held="$(id -G quasar | tr " " "\n")"
  grep -qx 4242 <<<"$held"
  grep -qx 4343 <<<"$held"
  if grep -qxE "0|65534" <<<"$held"; then
    echo "FAIL: the app user was granted gid 0 or the overflow gid: $held" >&2; exit 1
  fi
  if getent group 4444 >/dev/null; then
    echo "FAIL: a group was created for a world-rw node" >&2; exit 1
  fi
  if [[ "$(stat -c "%n %a %g" /dev/input/* /dev/snd/*)" != "$modes_before" ]]; then
    echo "FAIL: the hook changed a node'"'"'s mode or group" >&2; exit 1
  fi
'
qv_pass "direct-mode device-group hook: grants by membership only, never gid 0 / unmapped / world-rw"

echo "quasar-kde launcher tests passed"
