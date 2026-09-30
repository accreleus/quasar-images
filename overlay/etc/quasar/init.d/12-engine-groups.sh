#!/usr/bin/env bash
# Make the application user a member of each group the node-agent names in
# QUASAR_APP_ENGINE_GROUPS, so the `setpriv --init-groups` drop keeps it.
#
# The agent sets it where a device the app must open is granted to a group that
# no `--group-add` can hand over (the drop discards those) and that this image
# cannot infer from the node itself. Today that is rootless Docker, with value
# `0`: there is no per-container id mapping, so gid 0 inside the container is
# the Quasar account's group on the host, the one host preparation grants the
# session's input and DRM nodes to by ACL (quasar #428).
#
# This is the ONLY way the app user joins gid 0. 10-dri-device-groups.sh still
# refuses it for its own stat-based inference: there a root-group node is a
# misconfigured host. Here it is the agent's explicit decision for its engine.
#
# The value is comma-separated gids. Anything else is logged and ignored as a
# whole: a half-parsed grant is worse than none.
set -euo pipefail

log() { printf '%s quasar-base: %s\n' "$(date -Iseconds)" "$*" >&2; }

value="${QUASAR_APP_ENGINE_GROUPS:-}"
[[ -n "$value" ]] || exit 0

if ! [[ "$value" =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]]; then
  log "WARNING: ignoring QUASAR_APP_ENGINE_GROUPS='$value': expected comma-separated gids"
  exit 0
fi

: "${PUID:=1000}" "${PGID:=1000}"
user="$(getent passwd "$PUID" 2>/dev/null | cut -d: -f1 || true)"
if [[ -z "$user" ]]; then
  # quasar-entrypoint creates the user before running hooks, so this means the
  # hook was invoked out of context.
  exit 0
fi

IFS=, read -ra gids <<<"$value"
for gid in "${gids[@]}"; do
  gid=$((10#$gid))
  if (( gid > 65535 )); then
    log "WARNING: ignoring engine group $gid: out of range"
    continue
  fi
  [[ "$gid" == "$PGID" ]] && continue

  gname="$(getent group "$gid" 2>/dev/null | cut -d: -f1 || true)"
  if [[ -z "$gname" ]]; then
    gname="quasar-engine-$gid"
    if ! groupadd --gid "$gid" "$gname" 2>/dev/null; then
      log "WARNING: could not create a group for engine gid $gid"
      continue
    fi
  fi
  if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qxF "$gname"; then
    continue
  fi
  if usermod -aG "$gname" "$user" 2>/dev/null; then
    log "granted $user membership of $gname (gid $gid): named by the node-agent for this engine"
  else
    log "WARNING: could not add $user to $gname (gid $gid)"
  fi
done
