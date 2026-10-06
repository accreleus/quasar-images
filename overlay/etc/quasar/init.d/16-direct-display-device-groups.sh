#!/usr/bin/env bash
# Direct display only (QUASAR_DIRECT_DISPLAY=1, quasar#453): make the application
# user a MEMBER of the groups that own the host's input and sound nodes, so the
# uid/gid drop at the end of quasar-entrypoint keeps them.
#
# A console session's desktop opens the real keyboard, mouse, controllers and
# sound card itself: KWin through libinput, PipeWire through ALSA. The agent
# bind-mounts the host's /dev/input directory (plus a device-cgroup rule, so a
# device plugged in later opens too) and passes /dev/snd. Those nodes are 0660
# and owned by the host's input and audio groups, and `setpriv --init-groups`
# discards every gid the engine granted (see 10-dri-device-groups.sh, which
# solves the same problem for /dev/dri the same way: membership, not
# --keep-groups).
#
# WHY DIRECT ONLY. In a streamed session the input nodes the agent passes are
# Quasar's VIRTUAL keyboard and mouse, read by the agent's compositor, plus
# gamepads. Membership of their group would let the app (Steam) open and
# EVIOCGRAB the virtual keyboard and mouse and starve the compositor, which is
# exactly what 15-input-device-perms.sh is written to prevent. So this hook does
# nothing unless the agent asked for direct display.
#
# The membership is by group, so it also covers a device plugged in after start
# (the kernel gives it the same group). It cannot cover a group that no node
# showed at start: a host with no keyboard plugged in when the session starts
# has no input node to read the group from.
#
# The deliberate no-ops, as in 10-dri-device-groups.sh:
#   * a world-rw node            the app user can already open it.
#   * gid 0                      NEVER granted. On rootless Docker the agent
#                                names it in QUASAR_APP_ENGINE_GROUPS instead
#                                (12-engine-groups.sh); here it would mean
#                                handing the app user root's group.
#   * gid 65534                  an unmapped host group (rootless): membership
#                                grants nothing.
set -euo pipefail

[[ "${QUASAR_DIRECT_DISPLAY:-}" == "1" ]] || exit 0

log() { printf '%s quasar-base: %s\n' "$(date -Iseconds)" "$*" >&2; }

: "${PUID:=1000}" "${PGID:=1000}"

user="$(getent passwd "$PUID" 2>/dev/null | cut -d: -f1 || true)"
if [[ -z "$user" ]]; then
  # quasar-entrypoint creates the user before running hooks, so this means the
  # hook was invoked out of context.
  exit 0
fi

shopt -s nullglob
declare -A granted=()
warned_root=0

for node in /dev/input/event* /dev/snd/*; do
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
