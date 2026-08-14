#!/usr/bin/env bash
# Steam Big Picture needs a D-Bus SYSTEM bus and a reachable NetworkManager.
#
# quasar-images#4: BPM hung forever on "Waiting for network…" even though Steam
# itself was online (connection_log.txt "Connectivity test … OK! result=Connected").
# The evidence chain, in order:
#
#   logs/client_networkmanager.txt : "Init: failed to create a NetworkManager client"
#   logs/cef_log.txt              : "SystemNetworkStore - ERROR TypeError:
#                                    SteamClient.System.Network.RegisterForDeviceChanges
#                                    is not a function"
#
# Steam's client builds its network subsystem on libnm (nm_client_new()) over the
# D-Bus system bus. When that client fails to construct, the client never registers
# the SteamClient.System.Network.* bindings into the UI's JS context, so the BPM
# SystemNetworkStore — which initialises BEFORE login — throws and never reaches a
# "network up" state. The UI blocks regardless of real connectivity.
#
# games-on-whales' steam image (apps/steam/build-fedora/scripts/system-services.sh)
# is the validated reference for this exact shape and does the same two things:
# `dbus-daemon --system --fork --nosyslog` then `NetworkManager`.
#
# This hook runs as ROOT from quasar-entrypoint's /etc/quasar/init.d/ chain,
# before privileges are dropped to PUID/PGID — the only point in the container's
# life where a system bus can be created.
#
# NOTE ON SCOPE: this is a container-shaped workaround, not a Steam fix. Steam
# hard-couples a UI-level store to a host service that has no business existing
# inside an app container; a headless/containerised Steam ought to degrade to
# "assume online". Until Valve changes that, an in-container NM is the only lever.
# The bus is created INSIDE the container — the host's system bus is never
# mounted in (an app container is a tenant workload).
set -uo pipefail

log() { printf '%s quasar-steam-services: %s\n' "$(date -Iseconds)" "$*" >&2; }

if [[ "$(id -u)" != "0" ]]; then
  log "not running as root; skipping system-service startup"
  exit 0
fi

if [[ "${QUASAR_STEAM_SYSTEM_SERVICES:-1}" != "1" ]]; then
  log "QUASAR_STEAM_SYSTEM_SERVICES=0; skipping system dbus + NetworkManager"
  exit 0
fi

# --- D-Bus system bus --------------------------------------------------------
if [[ -S /run/dbus/system_bus_socket ]]; then
  log "system bus socket already present; not starting a second dbus-daemon"
else
  mkdir -p /run/dbus
  if dbus-daemon --system --fork --nosyslog; then
    log "started D-Bus system bus"
  else
    log "WARNING: dbus-daemon --system failed; Steam's network store will not initialise"
  fi
fi

# --- NetworkManager ----------------------------------------------------------
# The container is given --cap-drop ALL (plus a small, non-NET_ADMIN set), so NM
# cannot and must not reconfigure the interface. It runs here purely as a D-Bus
# *observer*: it adopts the container's already-configured interface as an
# externally-managed connection and answers the queries libnm makes on Steam's
# behalf. /etc/NetworkManager/conf.d/00-quasar.conf (shipped by the image) sets
# no-auto-default=* so NM never tries to create its own DHCP profile — on a
# docker bridge network there is no DHCP server, and an attempted activation
# could flush the address docker assigned.
if ! command -v NetworkManager >/dev/null 2>&1; then
  log "WARNING: NetworkManager is not installed; Steam Big Picture will hang on 'Waiting for network'"
  exit 0
fi

# NetworkManager self-daemonizes and reparents to tini, exactly like ibus-daemon
# in the launcher — this hook must return so the entrypoint can continue.
if NetworkManager; then
  log "started NetworkManager"
else
  log "WARNING: NetworkManager failed to start"
  exit 0
fi

# Steam's client constructs its NM client early; make sure the well-known name is
# on the bus before the entrypoint proceeds. Bounded — a missing NM degrades to
# the old behaviour rather than blocking container startup.
nm_wait="${QUASAR_STEAM_NM_WAIT:-15}"
[[ "$nm_wait" =~ ^[0-9]+$ ]] || nm_wait=15
for _ in $(seq 1 $(( nm_wait * 4 ))); do
  if dbus-send --system --print-reply --dest=org.freedesktop.DBus \
       /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
       string:org.freedesktop.NetworkManager 2>/dev/null | grep -q 'boolean true'; then
    log "org.freedesktop.NetworkManager is on the system bus"
    exit 0
  fi
  sleep 0.25
done
log "WARNING: org.freedesktop.NetworkManager did not appear within ${nm_wait}s"
exit 0
