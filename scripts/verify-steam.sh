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

  # Launcher wiring: Gamescope runs in its own process group (shielded from the
  # group TERM) with a trap that asks Steam to shut down cleanly first.
  grep -q "setsid gamescope" "$steam"
  grep -q "trap request_shutdown TERM INT" "$steam"
  grep -q "QUASAR_STEAM_GAMESCOPE:-1" "$steam"

  # Default UI mode is the games-on-whales-validated bigpicture path.
  grep -q "QUASAR_STEAM_UI_MODE:-bigpicture" "$steam"

  # Game-foreground invariant: -gamepadui must never appear without the full
  # SteamOS deck-session unit (a partial gamepadui config pins focus to the UI).
  if grep -q -- "-gamepadui" "$steam"; then
    grep -q -- "-gamepadui -steamos3 -steampal -steamdeck" "$steam"
  fi

  # Steam must bind Gamescope Xwayland, not the nested Wayland socket.
  grep -q "unset WAYLAND_DISPLAY" "$client"

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

echo "quasar-steam structural checks passed"
