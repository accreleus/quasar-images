#!/usr/bin/env bash
# Open read/write on the gamepad evdev nodes the launcher passed in (--device).
# Docker materializes them root-owned inside the container, but the application
# runs as the unprivileged PUID/PGID user — without this, SDL/Steam can discover
# a gamepad via the mounted udev records yet fail to open it (silently: the pad
# just never appears in-game). Write access is required too (rumble/LEDs).
#
# ONLY joystick/gamepad nodes are opened. The Quasar virtual keyboard and mouse
# are read host-side by the compositor (libinput) and reach the app through the
# Wayland seat; if Steam can open those same nodes in the container it grabs
# them (EVIOCGRAB is kernel-exclusive) and starves the compositor — cursor and
# keyboard go dead session-wide. Classification comes from the mounted udev
# records (/run/udev/data/c13:<minor>), the same source SDL/Steam use for
# discovery: no record, or a keyboard/mouse/pointer record, leaves the node
# root-owned and therefore invisible to the app.
# Best-effort: images without passed devices simply have nothing to match.
set -euo pipefail

shopt -s nullglob
for node in /dev/input/event*; do
  minor_hex="$(stat -c %T "$node" 2>/dev/null)" || continue
  record="/run/udev/data/c13:$((16#$minor_hex))"
  [[ -r "$record" ]] || continue
  grep -q '^E:ID_INPUT_JOYSTICK=1$' "$record" || continue
  if grep -Eq '^E:ID_INPUT_(KEYBOARD|MOUSE|POINTINGSTICK|TOUCHPAD)=1$' "$record"; then
    continue
  fi
  chmod 0666 "$node" || true
done
