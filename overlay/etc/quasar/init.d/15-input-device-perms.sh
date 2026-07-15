#!/usr/bin/env bash
# Open read/write on the evdev nodes the launcher passed in (--device). Docker
# materializes them root-owned inside the container, but the application runs
# as the unprivileged PUID/PGID user — without this, SDL/Steam can discover a
# gamepad via the mounted udev records yet fail to open it (silently: the pad
# just never appears in-game). Write access is required too (rumble/LEDs).
# Best-effort: images without passed devices simply have nothing to match.
set -euo pipefail

shopt -s nullglob
for node in /dev/input/event*; do
  chmod 0666 "$node" || true
done
