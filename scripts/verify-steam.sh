#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

for executable in steam gamescope bwrap quasar-steam quasar-steam-client xprop; do
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
  grep -q "QUASAR_STEAM_GAME_EXIT_DEBOUNCE:-8" "$steam"
  # Registry-arbitrated exit redesign (2026-08-02): the total-extension safety
  # valve knob, default 24s beyond the first debounce expiry.
  grep -q "QUASAR_STEAM_EXIT_REGISTRY_CAP:-24" "$steam"
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

  # Phase B: session state-file reporting (game-exit-lifecycle spec §B.1).
  # Writes must be atomic (tmp file in the SAME directory, then mv) and must
  # no-op silently when the bind-mounted directory is absent/unwritable -- an
  # old agent or a bare `docker run` must see zero behaviour change.
  grep -q "QUASAR_SESSION_STATE_DIR:-/run/quasar/session" "$steam"
  grep -q "write_app_state" "$steam"
  grep -q "app-state" "$steam"
  # These three contain a literal dollar sign in the pattern, so the regex
  # must be wrapped using the single-quote-escape idiom already established
  # in this file (see the kill -[A-Z]+ -[0-9$] check above) -- a bare quoted
  # pattern here would prematurely close this scripts own outer quoting.
  # Two more traps live here (both caught the suite red on a correct image):
  # an unescaped "$" mid-pattern is an ERE end-anchor, not a literal dollar,
  # so a pattern containing "$dir"/"$tmp" followed by more text could never
  # match -- escape it as "\$". And a pattern that starts with "-d" is parsed
  # by grep as its --directories option unless guarded with "--".
  grep -qE -- '"'"'-d "\$dir" && -w "\$dir"'"'"' "$steam"
  grep -qE '"'"'printf .* > "\$tmp"'"'"' "$steam"
  grep -qE '"'"'mv -f -- "\$tmp" "\$dir/app-state"'"'"' "$steam"

  # The three state values must all be wired to a write_app_state call
  # somewhere in the file (game_running on entering running, game_exited
  # before the USR1 self-signal). client_only is only ever written on the
  # armed path (watch_appid set) -- an unarmed launcher-tile session must
  # write nothing at all (see write_app_state header comment) -- so assert
  # it specifically inside the watch_appid arming block rather than merely
  # present anywhere in the file.
  grep -A2 '"'"'if \[\[ -n "\$watch_appid" \]\]; then'"'"' "$steam" | grep -q "write_app_state client_only"
  grep -q "write_app_state game_running" "$steam"
  grep -q "write_app_state game_exited" "$steam"

  # game_exited must be written strictly before the USR1 self-signal so the
  # agent final teardown read sees the true outcome, not a stale
  # game_running -- assert the two lines are adjacent in that order rather
  # than just both present anywhere in the file.
  grep -A2 "write_app_state game_exited" "$steam" | grep -q "kill -USR1"

  # PRODUCT RULE (Michael, 2026-08-02, revised 2026-08-02 to registry
  # arbitration): the user must never see Big Picture after quitting a game,
  # but the reaper PROCESS going away is not itself the exit signal -- Steam
  # drops it during a title'"'"'s own startup hand-offs (Redout ~1s, Hades II
  # >4s, live-observed on Tower), so writing client_only at debounce ENTRY
  # (process-gone) blinks the loader on those hand-offs or races a kill.
  # Assert the debounce-entry write is GONE (negative-assert, explicit
  # if/exit -- a "!"-inverted grep is inert under set -e per the standing
  # convention in this file) ...
  if grep -A10 "entering debounce" "$steam" | grep -q "write_app_state client_only"; then
    echo "FAIL: client_only written immediately on running->debounce entry in $steam (must be gated on registry arbitration inside the debounce loop, not process-gone alone)" >&2
    exit 1
  fi
  # ... and assert the REPLACEMENT: client_only is gated on the registry
  # arbitration check inside the debounce state (registry_running_appid no
  # longer equals watch_appid, notified exactly once via registry_notified).
  # The pattern contains a literal "$" mid-string, which GNU grep treats as
  # an anchor unless escaped (same trap the -d "$dir" checks above already
  # document) -- escape it as "\$" and wrap with the single-quote-escape
  # idiom already established in this file so the embedded literal single
  # quotes survive the outer single-quoted docker -lc string.
  grep -A5 -E '"'"'running_appid" != "\$watch_appid" && "\$registry_notified" == "0"'"'"' "$steam" | grep -q "write_app_state client_only"

  # Foreground gate (Phase B "Foreground polish"): default-on knob, the two
  # corroborating X atoms, and the bounded (10s) process-only fallback so an
  # untagged title cannot wedge the watcher in waiting_for_start forever.
  grep -q "QUASAR_STEAM_FOREGROUND_CHECK:-1" "$steam"
  grep -q "foreground_gate_active" "$steam"
  grep -q "game_foreground" "$steam"
  grep -q "GAMESCOPECTRL_BASELAYER_APPID" "$steam"
  grep -q "STEAM_GAME" "$steam"
  grep -q "foreground_grace=10" "$steam"
  grep -q "falling back to process-only" "$steam"

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
