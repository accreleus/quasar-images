#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# shellcheck source=scripts/lib/verify-lib.sh
. "$root/scripts/lib/verify-lib.sh"
qv_init

# The image under test. `scripts/build.sh` tags what it builds with
# $QUASAR_IMAGE_TAG (default `dev`), so a verify script that hardcodes `:dev`
# silently checks a DIFFERENT image than the one just built -- which is exactly
# what happened on 2026-08-20: a freshly built quasar-steam passed every
# assertion while this script reported a failure, because it was reading a
# months-old `:dev` left on the box by another branch. Honour the same variable
# the builder uses, and allow an explicit override.
TAG="${QUASAR_IMAGE_TAG:-dev}"
STEAM_IMAGE="${QUASAR_STEAM_IMAGE:-quasar-steam:$TAG}"

echo "checking the session executables in $STEAM_IMAGE"
qv_image_has "$STEAM_IMAGE" \
  steam gamescope bwrap quasar-steam quasar-steam-client dbus-daemon NetworkManager

docker run --rm --entrypoint /bin/bash "$STEAM_IMAGE" -lc "$QV_GUARD"'
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

labels="$(docker image inspect "$STEAM_IMAGE" --format '{{json .Config.Labels}}')"
jq -e '.["org.quasar.image.contract"] == "1" and .["org.quasar.image.acceleration"] == "required"' <<<"$labels" >/dev/null

# Base ENTRYPOINT must not run tini with -g: with -g, tini forwards signals
# via a group-kill that is EPERM-fatal against the unprivileged (no CAP_KILL)
# reshaped process group -- the reconstructed 6551fe8 regression. Graceful
# shutdown is the launcher's job now (on_term() above), not tini's group-kill.
base_dockerfile="$root/images/quasar-base/Dockerfile"
assert_file "$base_dockerfile" "the base Dockerfile is what defines the ENTRYPOINT under test"
# refute_grep, not "!"-inverted grep: the inverted form is inert under errexit
# and would silently pass if -g were reintroduced.
refute_grep '^ENTRYPOINT \["/usr/bin/tini", "-g"' "$base_dockerfile" \
  "tini -g forwards signals by group-kill, which is EPERM-fatal without CAP_KILL"
assert_grep '^ENTRYPOINT \["/usr/bin/tini", "--", "/usr/local/bin/quasar-entrypoint"\]' "$base_dockerfile" \
  "the base entrypoint must be tini exec-ing quasar-entrypoint directly"

echo "quasar-steam structural checks passed"
