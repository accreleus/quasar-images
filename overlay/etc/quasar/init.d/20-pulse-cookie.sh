#!/usr/bin/env bash
# Publish the launcher-injected PulseAudio auth cookie into the app user's
# home. Some clients never see the PULSE_COOKIE env var — Steam's runtime
# scrubs it before starting its embedded Chromium audio service — and libpulse
# then falls back to ~/.config/pulse/cookie. With a persistent home that file
# is a stale cookie from an earlier session, and every fallback client gets
# "Access denied" from the current session's Pulse server. Refresh it at each
# container start so both paths agree.
set -euo pipefail

[[ -n "${PULSE_COOKIE:-}" && -r "${PULSE_COOKIE}" && -n "${HOME:-}" ]] || exit 0
install -o "${PUID:-1000}" -g "${PGID:-1000}" -m 0700 -d "${HOME}/.config" "${HOME}/.config/pulse"
install -o "${PUID:-1000}" -g "${PGID:-1000}" -m 0600 "${PULSE_COOKIE}" "${HOME}/.config/pulse/cookie"
