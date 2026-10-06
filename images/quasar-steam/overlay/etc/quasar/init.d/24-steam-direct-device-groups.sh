#!/usr/bin/env bash
# Direct display only (QUASAR_DIRECT_DISPLAY=1, quasar#457): make the app user a
# MEMBER of the groups owning the host's input, hidraw and sound nodes, so the
# uid/gid drop at the end of quasar-entrypoint keeps them. Steam Input reads
# physical controllers itself (evdev and hidraw), and Steam and games play to
# the console's own sound card. gamescope's keyboard, mouse and card still come
# from seatd (25-steam-direct-seatd.sh), not from this membership. A nested
# session never gets here: there the input nodes are Quasar's virtual devices,
# which the app must not be able to open (15-input-device-perms.sh).
#
# Membership, never a node change: in this mode /dev/input is the HOST's
# directory bind-mounted in, so a chmod or chgrp would rewrite the host's own
# device permissions. Nothing here touches a node (verify-steam-launcher.sh runs
# the whole init chain and checks). `setpriv --init-groups` rebuilds the groups
# from /etc/group (see 10-dri-device-groups.sh for the full story), so the host
# gid is written into /etc/group and the app user joined to it. Membership is by
# group, so it also covers a device plugged in later with the same group.
#
# The deliberate no-ops (as the KDE image's 16-kde-direct-device-groups.sh):
#   * a world-rw node      the app user can already open it.
#   * a group without rw   membership would not help; logged.
#   * gid 0                NEVER granted (root's group). On rootless Docker the
#                          agent names it in QUASAR_APP_ENGINE_GROUPS instead
#                          (12-engine-groups.sh).
#   * gid 65534            an unmapped host group (rootless): grants nothing.
set -euo pipefail

[[ "${QUASAR_DIRECT_DISPLAY:-}" == "1" ]] || exit 0

log() { printf '%s quasar-steam: %s\n' "$(date -Iseconds)" "$*" >&2; }

: "${PUID:=1000}" "${PGID:=1000}"
user="$(getent passwd "$PUID" 2>/dev/null | cut -d: -f1 || true)"
[[ -n "$user" ]] || exit 0

shopt -s nullglob
declare -A granted=()
warned_root=0

for node in /dev/input/event* /dev/hidraw* /dev/snd/*; do
  [[ -c "$node" ]] || continue
  gid="$(stat -Lc %g "$node" 2>/dev/null)" || continue
  mode="$(stat -Lc %a "$node" 2>/dev/null)" || continue
  [[ "$gid" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]+$ ]] || continue

  mode4="$(printf '%04d' "$mode")"
  group_bits="${mode4:2:1}"
  other_bits="${mode4:3:1}"
  if (( (other_bits & 6) == 6 )); then
    continue
  fi
  if (( (group_bits & 6) != 6 )); then
    log "WARNING: $node is mode $mode4 — its group has no read/write, so the app user cannot open it"
    continue
  fi
  if [[ "$gid" == 0 ]]; then
    if (( warned_root == 0 )); then
      log "WARNING: $node is owned by gid 0; NOT granting the app user root-group membership."
      warned_root=1
    fi
    continue
  fi
  if [[ "$gid" == 65534 || "$gid" == "$PGID" || -n "${granted[$gid]:-}" ]]; then
    continue
  fi
  granted[$gid]=1

  gname="$(getent group "$gid" 2>/dev/null | cut -d: -f1 || true)"
  if [[ -z "$gname" ]]; then
    gname="quasar-dev-$gid"
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
