#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

for executable in steam gamescope bwrap quasar-steam quasar-steam-client dbus-daemon NetworkManager; do
  docker run --rm --entrypoint /bin/bash quasar-steam:dev -lc "command -v $executable >/dev/null"
done

docker run --rm --entrypoint /bin/bash quasar-steam:dev -lc '
  set -e
  steam=/usr/local/bin/quasar-steam
  client=/usr/local/bin/quasar-steam-client

  # Launcher-owned graceful shutdown (quasar-images#1): no setsid/setpgid
  # anywhere (everything stays in tini'"'"'s direct descendant tree -- the
  # 6551fe8 FATAL was EPERM from a group-kill against a setsid-reshaped
  # group), and a trap that sends a single SIGTERM to the steam ELF process
  # (resolved via $HOME/.steam/steam.pid, falling back to `pgrep -x steam`) --
  # the PROVEN clean-quit mechanism (live-tested 2026-07-20). `steam.sh
  # -shutdown` is forwarded to the running instance over Steam'"'"'s client IPC
  # and silently ignored in this container, so it must never appear here.
  # NOTE: negative assertions must use explicit if/exit, not "! grep -q ...".
  # bash'"'"'s errexit (set -e) does not fire on a command whose exit status is
  # inverted by !, so "! grep -q ..." would silently PASS (never even print
  # a failure) if setsid/-g were reintroduced -- caught in review.
  if grep -q "setsid" "$steam"; then
    echo "FAIL: setsid present in $steam" >&2
    exit 1
  fi
  if grep -q "setpgid" "$steam"; then
    echo "FAIL: setpgid present in $steam" >&2
    exit 1
  fi
  # Same EPERM-FATAL class as setsid/-g: a negative-pid kill (group-kill) or
  # a signal-named group-kill (kill -TERM -$pid) targets the whole process
  # group, which is EPERM under --cap-drop ALL/no CAP_KILL against a
  # reshaped group -- must never be reintroduced.
  if grep -qE '"'"'kill[^|]* -- -|kill -[A-Z]+ -[0-9$]'"'"' "$steam"; then
    echo "FAIL: group-kill (negative-pid kill) present in $steam" >&2
    exit 1
  fi
  if grep -q -- "-shutdown" "$steam"; then
    echo "FAIL: steam.sh -shutdown present in $steam (proven ineffective -- forwarded to the running instance and ignored)" >&2
    exit 1
  fi
  grep -q "trap on_term TERM INT" "$steam"
  grep -q "resolve_steam_pid" "$steam"
  grep -q "steam.pid" "$steam"
  grep -q "pgrep -x steam" "$steam"
  grep -q "QUASAR_STEAM_SHUTDOWN_TIMEOUT:-8" "$steam"
  grep -q "QUASAR_STEAM_GAMESCOPE:-1" "$steam"

  # Default UI mode is the games-on-whales-validated bigpicture path.
  grep -q "QUASAR_STEAM_UI_MODE:-bigpicture" "$steam"

  # Game-foreground invariant: -gamepadui must never appear without the full
  # SteamOS deck-session unit (a partial gamepadui config pins focus to the UI).
  if grep -q -- "-gamepadui" "$steam"; then
    grep -q -- "-gamepadui -steamos3 -steampal -steamdeck" "$steam"
  fi

  # Steam must bind Gamescope Xwayland, not the nested Wayland socket. Display
  # wiring (DISPLAY export + outer-WAYLAND_DISPLAY unset) moved from the
  # steam-wrapper client into the quasar-steam launcher itself (52b55e2, the
  # GOW ready-socket handshake) -- this assertion was checking the wrong file
  # and had gone stale (silently, since it is a bare assertion with no FAIL
  # message: a failure here aborts the whole script under set -e with no
  # diagnostic, discovered while proving the group-kill fix green end-to-end).
  grep -q "unset WAYLAND_DISPLAY" "$steam"

  # ALSA-only clients route to the injected PulseAudio sink.
  test -f /etc/asound.conf
  grep -q "type pulse" /etc/asound.conf

  # 32-bit graphics userspace is present (NVIDIA driver libs are injected at runtime).
  test -e /usr/lib/libGL.so.1

  # 32-bit NVIDIA driver volume (issue #375): ldconfig must be told where to
  # look at /opt/quasar/nvidia-lib32, additive to the toolkit'"'"'s 64-bit injection into
  # the standard system paths — no driver libs are baked into the image.
  test -f /etc/ld.so.conf.d/90-quasar-nvidia-volume.conf
  grep -q "^/opt/quasar/nvidia-lib32$" /etc/ld.so.conf.d/90-quasar-nvidia-volume.conf
  grep -q "nvidia_32bit_volume" /usr/local/bin/quasar-gpu-init

  # The Quasar driver volume is the THIRD NVIDIA injection shape (alongside the
  # GOW /usr/nvidia volume and the container toolkit) and it needs its GBM
  # backend published into Mesa'"'"'s backend directory, or libgbm silently falls
  # back to Mesa, Mesa has no driver for nvidia-drm, Xwayland refuses glamor on
  # llvmpipe, and Steam'"'"'s CEF GPU process crash-loops -- the flickering Big
  # Picture logo that never reached a sign-in screen. The function must exist
  # AND be invoked: it shipped defined-but-never-called once, which validated as
  # a no-op with the bug fully intact.
  grep -q "nvidia_quasar_volume()" /usr/local/bin/quasar-gpu-init
  grep -qE "^nvidia_quasar_volume$" /usr/local/bin/quasar-gpu-init

  # D-Bus system bus + NetworkManager (quasar-images#4). Without them Steam'"'"'s
  # libnm client fails to construct, the client never registers
  # SteamClient.System.Network.*, and Big Picture'"'"'s SystemNetworkStore throws
  # pre-login -- the UI hangs on "Waiting for network" forever with a perfectly
  # online client. Proven by A/B on quasar-devbox 2026-08-09 (same image, same
  # home volume, QUASAR_STEAM_SYSTEM_SERVICES on/off).
  hook=/etc/quasar/init.d/20-steam-system-services.sh
  test -x "$hook"
  grep -q "dbus-daemon --system" "$hook"
  grep -q "NetworkManager" "$hook"
  # The host system bus must never be mounted in -- the bus is created here.
  if grep -q "/var/run/dbus\|--mount.*system_bus_socket" "$hook"; then
    echo "FAIL: $hook references a host D-Bus socket; the bus must be created in-container" >&2
    exit 1
  fi
  # NM must stay a read-only observer: no auto-created DHCP profile on a docker
  # bridge network (no DHCP server there; an activation attempt can flush the
  # address docker assigned).
  test -f /etc/NetworkManager/conf.d/00-quasar.conf
  grep -q "^no-auto-default=\*" /etc/NetworkManager/conf.d/00-quasar.conf
# Connectivity check must be configured or NM reports "limited" on the bridge
# device and every NM-gated app (Plasma applet, Discover, Steam) plays offline.
grep -q "^uri=http://nmcheck.gnome.org/check_network_status.txt" /etc/NetworkManager/conf.d/00-quasar.conf
'

labels="$(docker image inspect quasar-steam:dev --format '{{json .Config.Labels}}')"
jq -e '.["org.quasar.image.contract"] == "1" and .["org.quasar.image.acceleration"] == "required"' <<<"$labels" >/dev/null

# Base ENTRYPOINT must not run tini with -g: with -g, tini forwards signals
# via a group-kill that is EPERM-fatal against the unprivileged (no CAP_KILL)
# reshaped process group -- the reconstructed 6551fe8 regression. Graceful
# shutdown is the launcher's job now (on_term() above), not tini's group-kill.
base_dockerfile="$root/images/quasar-base/Dockerfile"
test -f "$base_dockerfile"
# Same explicit if/exit form as the setsid check above -- "!"-inverted grep is
# inert under set -e and would silently pass if -g were reintroduced.
if grep -q '^ENTRYPOINT \["/usr/bin/tini", "-g"' "$base_dockerfile"; then
  echo "FAIL: tini -g present in $base_dockerfile" >&2
  exit 1
fi
grep -q '^ENTRYPOINT \["/usr/bin/tini", "--", "/usr/local/bin/quasar-entrypoint"\]' "$base_dockerfile"

echo "quasar-steam structural checks passed"
