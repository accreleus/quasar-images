#!/usr/bin/env bash
# Direct display only (QUASAR_DIRECT_DISPLAY=1, quasar#457): make the app user a
# MEMBER of the group owning each /dev/snd node, so Steam and games can play to
# the console's own sound card after the uid/gid drop. (A nested session plays
# to the PulseAudio sink the node-agent injects and needs none of this.) The
# drop is `setpriv --init-groups`, which rebuilds the groups from /etc/group --
# see 10-dri-device-groups.sh for the full story; this is the same mechanism for
# the sound nodes.
#
# /dev/input is deliberately NOT covered. gamescope opens keyboards and mice
# through seatd (wlroots' libinput backend opens every device via libseat), so
# the app user needs no access of its own; and an app that CAN open those nodes
# can EVIOCGRAB them away from the compositor (15-input-device-perms.sh has that
# history). Gamepads keep their existing path, 15-input-device-perms.sh.
#
# Never gid 0, as in 10-dri-device-groups.sh.
set -euo pipefail

[[ "${QUASAR_DIRECT_DISPLAY:-}" == "1" ]] || exit 0

log() { printf '%s quasar-steam: %s\n' "$(date -Iseconds)" "$*" >&2; }

: "${PUID:=1000}" "${PGID:=1000}"
user="$(getent passwd "$PUID" 2>/dev/null | cut -d: -f1 || true)"
[[ -n "$user" ]] || exit 0

shopt -s nullglob
declare -A granted=()
for node in /dev/snd/*; do
  [[ -c "$node" ]] || continue
  gid="$(stat -Lc %g "$node" 2>/dev/null)" || continue
  [[ "$gid" =~ ^[0-9]+$ ]] || continue
  [[ "$gid" == 0 || "$gid" == "$PGID" || -n "${granted[$gid]:-}" ]] && continue
  granted[$gid]=1

  gname="$(getent group "$gid" 2>/dev/null | cut -d: -f1 || true)"
  if [[ -z "$gname" ]]; then
    gname="quasar-snd-$gid"
    if ! groupadd --gid "$gid" "$gname" 2>/dev/null; then
      log "WARNING: could not create a group for gid $gid; $node stays unreadable to $user"
      continue
    fi
  fi
  if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qxF "$gname"; then
    continue
  fi
  if usermod -aG "$gname" "$user" 2>/dev/null; then
    log "granted $user membership of $gname (gid $gid) for $node"
  else
    log "WARNING: could not add $user to $gname (gid $gid); $node stays unreadable"
  fi
done
