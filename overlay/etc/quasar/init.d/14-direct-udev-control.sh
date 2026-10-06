#!/usr/bin/env bash
# Direct display (QUASAR_DIRECT_DISPLAY=1, quasar#453): libudev listens for
# hotplug only when /run/udev/control exists, and the node agent does not hand in
# the host's real control socket (container root could steer the host's udevd
# through it). An empty placeholder is all libudev looks for; the events arrive
# over netlink in the host's network namespace.
set -euo pipefail

[[ "${QUASAR_DIRECT_DISPLAY:-}" == "1" ]] || exit 0
[[ -e /run/udev/control ]] && exit 0

mkdir -p /run/udev
install -m 0444 /dev/null /run/udev/control
