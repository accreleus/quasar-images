#!/usr/bin/env bash
# Make the application user a MEMBER of the group that owns each /dev/dri node,
# so the uid/gid drop at the end of quasar-entrypoint keeps GPU access.
#
# WHY THIS EXISTS (root-caused 2026-09-02, quasar-images#…):
# Host DRM nodes are 0660 — typically root:render for renderD*, root:video for
# card*. The Quasar node-agent therefore launches app containers with
# `--device /dev/dri --group-add <render gid> --group-add <video gid>`, and
# Docker grants those gids as SUPPLEMENTARY groups of the container's initial
# (root) process. But quasar-entrypoint drops to the app user with
#
#     setpriv --reuid=$PUID --regid=$PGID --init-groups …
#
# and `--init-groups` REINITIALIZES the supplementary set from /etc/group for
# the target user (initgroups(3)) — silently discarding every gid Docker
# granted. The app then runs as uid 1000 in exactly one group, cannot open
# /dev/dri/renderD128, and Vulkan enumeration collapses to llvmpipe: gamescope
# aborts on the missing VK_EXT_physical_device_drm, and desktop images software
# render without saying so.
#
# The fix is membership, not `--keep-groups`. Writing the gids into /etc/group
# makes `--init-groups` produce them, which keeps the drop's precise semantics
# for everything else (a stray host gid the agent never intended to grant is
# still dropped), and it is discoverable afterwards — `id` inside the container
# names the groups instead of them appearing by inheritance.
#
# The three deliberate no-ops:
#   * no /dev/dri (a non-GPU container)      — nothing to iterate.
#   * a world-rw node (0666)                 — the app user can already open it.
#   * gid 0                                  — NEVER granted. A 0660 root:root
#     node is a misconfigured host; granting the app user gid 0 to paper over it
#     would hand it every other root-group-owned file in the image. It stays
#     broken and is logged, mirroring the node-agent's own rule.
set -euo pipefail

log() { printf '%s quasar-base: %s\n' "$(date -Iseconds)" "$*" >&2; }

: "${PUID:=1000}" "${PGID:=1000}"

user="$(getent passwd "$PUID" 2>/dev/null | cut -d: -f1 || true)"
if [[ -z "$user" ]]; then
  # quasar-entrypoint creates the user before running hooks, so this means the
  # hook was invoked out of context. Nothing to do rather than a hard failure.
  exit 0
fi

shopt -s nullglob
declare -A granted=()
warned_root=0

for node in /dev/dri/*; do
  # /dev/dri also holds by-path/ (a directory of symlinks), which -c skips.
  # stat -L so a node that IS a symlink is read as the device it points at.
  [[ -c "$node" ]] || continue
  gid="$(stat -Lc %g "$node" 2>/dev/null)" || continue
  mode="$(stat -Lc %a "$node" 2>/dev/null)" || continue
  [[ "$gid" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]+$ ]] || continue

  mode4="$(printf '%04d' "$mode")"
  group_bits="${mode4:2:1}"
  other_bits="${mode4:3:1}"

  # World rw already: membership would add nothing.
  if (( (other_bits & 6) == 6 )); then
    continue
  fi
  # Group bits do not grant rw: membership would not help either, and the node
  # is unusable by anyone but its owner. Say so — it is a host misconfiguration.
  if (( (group_bits & 6) != 6 )); then
    log "WARNING: $node is mode $mode4 — its group has no read/write, so the app user cannot open it"
    continue
  fi

  if [[ "$gid" == 0 ]]; then
    if (( warned_root == 0 )); then
      log "WARNING: $node is owned by gid 0; NOT granting the app user root-group membership."
      log "         The host's DRM nodes should be root:render / root:video, not root:root."
      warned_root=1
    fi
    continue
  fi

  # Already the app user's primary group, or a gid a previous node granted.
  if [[ "$gid" == "$PGID" || -n "${granted[$gid]:-}" ]]; then
    continue
  fi
  granted[$gid]=1

  gname="$(getent group "$gid" 2>/dev/null | cut -d: -f1 || true)"
  if [[ -z "$gname" ]]; then
    # The host's render/video gids usually do not exist in a Fedora container
    # (Fedora's own `render` is 39, the host's here was 991), so the group has
    # to be created by gid before anyone can be a member of it. The name is
    # synthetic and namespaced so it can never collide with a distro group.
    gname="quasar-dri-$gid"
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
