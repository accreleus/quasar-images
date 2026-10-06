#!/usr/bin/env bash
# Direct display only (QUASAR_DIRECT_DISPLAY=1, quasar#457): start seatd, so
# gamescope can take the monitor on its DRM backend from the unprivileged app
# user. seatd opens the card node (and becomes DRM master on it) and every input
# node on gamescope's behalf and hands it the fds; gamescope reaches it through
# libseat with LIBSEAT_BACKEND=seatd, which the launcher sets. Nested sessions
# never start it.
#
# Why seatd, and why like this (proven by hand on the console host, quasar#453):
#   * Fedora's libseat is built with no builtin backend, and there is no logind
#     in the container, so a seat daemon is the only way to a seat.
#   * seatd runs as the container's root, from this hook, before the drop to the
#     app user. Under rootless Docker that root is the unprivileged host account,
#     so the trust boundary is the same as everything else here.
#   * seatd 0.9.3 binds a FIXED socket, /run/seatd.sock (it ignores SEATD_SOCK
#     server-side and has no -s), and its -u/-g take user and group NAMES, not
#     ids. The socket is owned by the app user and group so only they can use it.
#   * SEATD_VTBOUND=0: a container has no VT to bind to, and the console host's
#     own VT stays the host's business.
# A container restart re-runs the init chain against the same /run, so a socket
# left by the previous run is removed first (otherwise the wait below would be
# satisfied by a dead socket) and a seatd that is already running is kept.
set -euo pipefail

[[ "${QUASAR_DIRECT_DISPLAY:-}" == "1" ]] || exit 0

log() { printf '%s quasar-steam: %s\n' "$(date -Iseconds)" "$*" >&2; }

: "${PUID:=1000}" "${PGID:=1000}"
sock=/run/seatd.sock

if pgrep -x seatd >/dev/null 2>&1 && [[ -S "$sock" ]]; then
  log "seatd already running"
  exit 0
fi

if ! command -v seatd >/dev/null 2>&1; then
  log "ERROR: direct display needs seatd and this image has none"
  exit 1
fi

user="$(getent passwd "$PUID" | cut -d: -f1 || true)"
group="$(getent group "$PGID" | cut -d: -f1 || true)"
if [[ -z "$user" || -z "$group" ]]; then
  log "ERROR: no user/group for PUID=$PUID PGID=$PGID; cannot give seatd's socket to the app user"
  exit 1
fi

mkdir -p /run
rm -f "$sock"
# Detached from this hook: quasar-entrypoint goes on to exec the app, and seatd
# stays behind as a child of tini. Its log goes to the container's stderr.
SEATD_VTBOUND=0 seatd -u "$user" -g "$group" -l info </dev/null >&2 &

for _ in $(seq 1 100); do
  [[ -S "$sock" ]] && break
  sleep 0.05
done
if [[ ! -S "$sock" ]]; then
  log "ERROR: seatd did not create $sock within 5s"
  exit 1
fi
log "seatd ready: $sock for $user:$group"
