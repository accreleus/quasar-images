#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# shellcheck source=scripts/lib/verify-lib.sh
. "$root/scripts/lib/verify-lib.sh"
qv_init

# The image under test. `scripts/build.sh` tags what it builds with
# $QUASAR_IMAGE_TAG (default `dev`), so a verify script that hardcodes `:dev`
# silently checks a DIFFERENT image than the one just built -- the 2026-08-20
# bug that `develop` f7f8012 fixed across the other verify scripts. Honour the
# same variable the builder uses, and allow an explicit override.
TAG="${QUASAR_IMAGE_TAG:-dev}"
XFCE_IMAGE="${QUASAR_XFCE_IMAGE:-quasar-xfce:$TAG}"

echo "checking the session executables in $XFCE_IMAGE"
qv_image_has "$XFCE_IMAGE" \
  startxfce4 xfce4-session xfwm4 xfce4-panel xfdesktop Xwayland xset \
  dbus-run-session flatpak gnome-software firefox steam bwrap quasar-xfce \
  xdg-user-dirs-update

# Zero gamescope/Big-Picture weight: this is a plain X11 desktop nested on a
# rootful Xwayland, and a gamescope that reappeared would mean the image picked
# up the quasar-steam layer set by accident.
qv_image_lacks "$XFCE_IMAGE" gamescope

# A streamed session has no local display to blank or power down, and neither
# package is configured here -- their presence means the package set drifted.
qv_image_lacks "$XFCE_IMAGE" xfce4-screensaver xfce4-power-manager

echo "checking the launcher contract, baked defaults, and branding"
docker run --rm --entrypoint /bin/bash "$XFCE_IMAGE" -lc "$QV_GUARD"'
  xfce=/usr/local/bin/quasar-xfce

  # In-image assertion helpers. The host-side verify-lib.sh is not in the
  # container, and a bare `grep -q` under errexit exits 1 having printed
  # nothing at all -- so every check states what it looked for and why.
  need() {  # need <pattern> <file> <why>
    grep -Eq -- "$1" "$2" && return 0
    echo "FAIL: $2 does not match /$1/ -- $3" >&2
    exit 1
  }
  deny() {  # deny <pattern> <file> <why>
    grep -Eq -- "$1" "$2" || return 0
    echo "FAIL: $2 matches /$1/ and must not -- $3" >&2
    grep -En -- "$1" "$2" >&2 || true
    exit 1
  }
  have_file() {  # have_file <path> <why>
    test -f "$1" && return 0
    echo "FAIL: $1 is missing -- $2" >&2
    exit 1
  }

  # --- Launcher-owned graceful shutdown (quasar-images#1) -------------------
  # Same contract as the Steam and KDE launchers: no setsid/setpgid/group-kill
  # anywhere, so everything stays in tini`s direct descendant tree -- there is
  # no process group to kill and no way to reproduce the 6551fe8 EPERM-FATAL.
  # NOTE: these are negative assertions and must NOT be written "! grep -q".
  # bash`s errexit does not fire on a !-inverted status, so such a line can
  # never fail; it reads as a guard and is a no-op.
  deny "setsid"  "$xfce" "the launcher must not detach children into a new session"
  deny "setpgid" "$xfce" "the launcher must not move children into a new process group"
  deny "kill[^|]* -- -|kill -[A-Z]+ -[0-9$]" "$xfce" \
       "a negative-pid group kill is the 6551fe8 EPERM-FATAL shape"

  need "trap on_term TERM INT" "$xfce" "the launcher must own the TERM relay"
  need "QUASAR_XFCE_SHUTDOWN_TIMEOUT:-8"    "$xfce" "the session shutdown wait must stay bounded"
  need "QUASAR_XFCE_COMPOSITOR_TIMEOUT:-30" "$xfce" "the compositor-socket wait must stay bounded"

  # --- Flatpak, store, and the agent share ---------------------------------
  need "flatpak remote-add --user --if-not-exists flathub" "$xfce" \
       "Flathub is added per-user at session start, never baked system-wide"
  have_file /var/lib/flatpak/repo/config "the system Flatpak repo must be initialised at build time"
  if compgen -G "/usr/lib64/gnome-software/plugins-*/libgs_plugin_fwupd.so" >/dev/null; then
    echo "FAIL: the gnome-software fwupd plugin is present -- a container has no firmware to update" >&2
    exit 1
  fi
  need "xdg-user-dirs-update" "$xfce" "the session must create the XDG user dirs in the managed home"
  need "/run/quasar/share"    "$xfce" "agent-provided menu entries mount here"

  # X11-only session: every Flatpak app must stay inside the nested X session
  # rather than reaching the parent compositor directly.
  need "flatpak override --user --nosocket=wayland" "$xfce" \
       "without it a Flatpak app talks to the PARENT compositor, outside the session"

  # --- Sizing: nothing baked, everything from the session mode (quasar#384) --
  need "QUASAR_XFCE_WIDTH:-\$\{QUASAR_STREAM_WIDTH:-1920\}"   "$xfce" "stream width must win over any image default"
  need "QUASAR_XFCE_HEIGHT:-\$\{QUASAR_STREAM_HEIGHT:-1080\}" "$xfce" "stream height must win over any image default"
  need "-geometry" "$xfce" "Xwayland is sized with -geometry WxH"
  need "dbus-run-session -- startxfce4" "$xfce" "the session needs its own bus"
  need "/tmp/.X11-unix" "$xfce" "the rootful Xwayland socket dir must be prepared"

  # The inverse of quasar-kde: the parent Wayland socket is scoped to
  # Xwayland`s own env, and the session itself is pure X11.
  need "^unset WAYLAND_DISPLAY$" "$xfce" "the XFCE session must not see the parent Wayland socket"
  need "export XDG_SESSION_TYPE=x11"   "$xfce" "session type must be x11"
  need "export XDG_CURRENT_DESKTOP=XFCE" "$xfce" "desktop id must be XFCE"
  need "export DESKTOP_SESSION=xfce"   "$xfce" "session id must be xfce"
  need "export GDK_BACKEND=x11"        "$xfce" "GTK apps must use the X11 backend"
  need "export QT_QPA_PLATFORM=xcb"    "$xfce" "Qt apps must use the xcb backend"
  need "export MOZ_ENABLE_WAYLAND=0"   "$xfce" "Firefox must not try the parent Wayland socket"

  if env | grep -qE "^QUASAR_(XFCE|STREAM)_(WIDTH|HEIGHT|REFRESH|FPS)="; then
    echo "FAIL: a session mode is baked as an image ENV (quasar#384) -- it would shadow the session mode" >&2
    exit 1
  fi

  # --- File capabilities ----------------------------------------------------
  # This package set was checked and came back empty, so unlike quasar-kde there
  # is no setcap -r in the Dockerfile. The assertion is what keeps that true
  # across a package bump: pressure-vessel rejects a bwrap carrying caps, and a
  # capability on the session binaries is a privilege the image never asked for.
  for b in /usr/bin/Xwayland /usr/bin/xfwm4 /usr/bin/xfce4-session \
           /usr/bin/xfce4-panel /usr/bin/xfdesktop /usr/bin/xfsettingsd; do
    capout="$(getcap "$b" || true)"
    if [[ -n "$capout" ]]; then
      echo "FAIL: $b carries a file capability ($capout); strip it with setcap -r in the Dockerfile" >&2
      exit 1
    fi
  done

  # No logind in the container, so the polkit agent would only sit there failing.
  need "^Hidden=true$" /etc/xdg/autostart/xfce-polkit.desktop \
       "the xfce-polkit autostart must stay suppressed (no logind in a container)"

  # --- Branding and the baked, read-only panel layout ----------------------
  # Baked under /etc/xdg so a user change in $HOME still wins.
  panel=/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml
  have_file "$panel" "the baked panel layout is what puts the Quasar menu on the panel"
  need "value=\"whiskermenu\"" "$panel" "the panel must carry the Whisker menu plugin"
  need "name=\"button-icon\" type=\"string\" value=\"quasar\"" "$panel" \
       "the Whisker menu button must use the Quasar icon"

  have_file /usr/share/icons/hicolor/scalable/apps/quasar.svg "the scalable Quasar icon"
  have_file /usr/share/icons/hicolor/256x256/apps/quasar.png  "the rasterised Quasar icon"
  if ! file /usr/share/icons/hicolor/256x256/apps/quasar.png | grep -q "PNG image data, 256 x 256"; then
    echo "FAIL: the 256x256 Quasar icon is not a 256x256 PNG -- the hicolor path lies about its size" >&2
    exit 1
  fi

  have_file /usr/share/applications/steam.desktop "the Steam desktop client must be launchable from the menu"
  have_file /usr/share/applications/org.gnome.Software.desktop "gnome-software is the store on XFCE"
'

echo "checking the image labels"
labels="$(docker image inspect "$XFCE_IMAGE" --format '{{json .Config.Labels}}')"
if ! jq -e '
      .["org.quasar.image.contract"] == "1"
  and .["org.quasar.image.acceleration"] == "required"
  and .["org.quasar.image.persist"] == "/home/quasar"
  and .["org.quasar.image.session"] == "desktop"
  and .["org.opencontainers.image.title"] == "Quasar XFCE desktop"
' <<<"$labels" >/dev/null; then
  echo "FAIL: $XFCE_IMAGE labels do not carry the desktop-session image contract" >&2
  echo "      got: $labels" >&2
  exit 1
fi

qv_pass "quasar-xfce structural checks passed ($XFCE_IMAGE)"
