#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

for executable in steam gamescope bwrap quasar-steam quasar-steam-client; do
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

  # Game-exit watcher (2026-08-02 game-exit-lifecycle spec, Phase A): armed
  # from a valid -applaunch <appid> pair, default-on, escape-hatch knob, and
  # a debounce knob. If any of these regress, a derived (game) tile session
  # silently stops ending on game exit -- assert the shape loudly.
  grep -q "QUASAR_STEAM_EXIT_ON_GAME_EXIT:-1" "$steam"
  grep -q "QUASAR_STEAM_GAME_EXIT_DEBOUNCE:-15" "$steam"
  grep -q "watch_appid" "$steam"
  grep -q "game_exit_watcher" "$steam"
  grep -q "game_running" "$steam"
  grep -q "registry_running_appid" "$steam"
  grep -q "RunningAppID" "$steam"

  # Detection must be /proc/*/cmdline NUL-split + exact-token compare, not
  # `pgrep -f` (self-match/substring traps on record -- AppId=620 must not
  # match AppId=6200). If this regresses to a pgrep -f the whole guard is
  # silently wrong, so assert both the exact form and the absence of the
  # forbidden one.
  grep -q "read -r -d .. tok" "$steam"
  if grep -qE "pgrep -f .*AppId" "$steam"; then
    echo "FAIL: pgrep -f AppId-style detection present in $steam (self-match/substring trap; use /proc/*/cmdline exact-token compare)" >&2
    exit 1
  fi

  # No setsid/setpgid anywhere in the watcher either -- same EPERM-FATAL
  # class as the launcher shutdown relay (checked above), so re-assert after
  # the watcher addition rather than trusting the earlier checks placement
  # in the file.
  if grep -q "setsid" "$steam"; then
    echo "FAIL: setsid present in $steam" >&2
    exit 1
  fi
  if grep -q "setpgid" "$steam"; then
    echo "FAIL: setpgid present in $steam" >&2
    exit 1
  fi

  # The watcher signals confirmed game-exit via USR1 to the launcher own pid
  # -- it must never call on_term() directly from its own forked subshell
  # (that would mutate a private copy of shutting_down, breaking the
  # docker-stop-mid-watcher-shutdown no-op-second-entry guarantee).
  grep -q "trap .*on_term.* USR1" "$steam"
  grep -q "game_exit_confirmed" "$steam"

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
