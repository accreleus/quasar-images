#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

for executable in startxfce4 xfce4-session xfwm4 xfce4-panel xfdesktop Xwayland xset \
                  dbus-run-session flatpak gnome-software firefox steam bwrap quasar-xfce \
                  xdg-user-dirs-update; do
  docker run --rm --entrypoint /bin/bash quasar-xfce:dev -lc "command -v $executable >/dev/null"
done

# gamescope must be ABSENT from this image (quasar-xfce carries zero gamescope/
# BPM weight by construction -- it inherits from quasar-steam-runtime, not
# quasar-steam). NOTE: negative assertions must use explicit if/exit, not
# "! command -v ...". bash's errexit (set -e) does not fire on a command whose
# exit status is inverted by !, so "! command -v gamescope" would silently
# PASS (never even print a failure) if gamescope were reintroduced -- the same
# lesson verify-steam.sh's setsid/setpgid checks are built around.
if docker run --rm --entrypoint /bin/bash quasar-xfce:dev -lc 'command -v gamescope' >/dev/null 2>&1; then
  echo "FAIL: gamescope present in quasar-xfce:dev (this image must carry zero gamescope/BPM weight)" >&2
  exit 1
fi

docker run --rm --entrypoint /bin/bash quasar-xfce:dev -lc '
  set -e
  xfce=/usr/local/bin/quasar-xfce

  # Launcher-owned graceful shutdown (quasar-images#1), same contract as the
  # Steam and KDE launchers: no setsid/setpgid/group-kill anywhere -- everything
  # stays in tini'"'"'s direct descendant tree, so there is no process group to
  # kill and no way to reproduce the 6551fe8 EPERM-FATAL.
  # NOTE: negative assertions must use explicit if/exit, not "! grep -q ...".
  # bash'"'"'s errexit (set -e) does not fire on a command whose exit status is
  # inverted by !, so "! grep -q ..." would silently PASS (never even print a
  # failure) if setsid/-g were reintroduced -- caught in review on verify-steam.sh.
  if grep -q "setsid" "$xfce"; then
    echo "FAIL: setsid present in $xfce" >&2
    exit 1
  fi
  if grep -q "setpgid" "$xfce"; then
    echo "FAIL: setpgid present in $xfce" >&2
    exit 1
  fi
  # Same EPERM-FATAL class as setsid/-g: a negative-pid kill (group-kill) or a
  # signal-named group-kill (kill -TERM -$pid) targets the whole process
  # group, which is EPERM under --cap-drop ALL/no CAP_KILL against a reshaped
  # group -- must never be reintroduced.
  if grep -qE '"'"'kill[^|]* -- -|kill -[A-Z]+ -[0-9$]'"'"' "$xfce"; then
    echo "FAIL: group-kill (negative-pid kill) present in $xfce" >&2
    exit 1
  fi
  grep -q "trap on_term TERM INT" "$xfce"
  grep -q "QUASAR_XFCE_SHUTDOWN_TIMEOUT:-8" "$xfce"
  grep -q "QUASAR_XFCE_COMPOSITOR_TIMEOUT:-30" "$xfce"
  grep -q "flatpak remote-add --user --if-not-exists flathub" "$xfce"
  # Flatpak/gnome-software usable at all (parity with quasar-kde, 2026-08-15):
  # the empty SYSTEM installation must exist or every flatpak call -- and
  # gnome-software'"'"'s flatpak backend -- fails "opening repo:
  # opendir(/var/lib/flatpak/repo)"; the fwupd gnome-software plugin must be
  # gone (no firmware in a container, only error dialogs).
  test -f /var/lib/flatpak/repo/config
  test ! -e /usr/lib64/gnome-software/plugins-*/libgs_plugin_fwupd.so
  grep -q "xdg-user-dirs-update" "$xfce"
  grep -q "/run/quasar/share" "$xfce"

  # Flatpak apps must not reach the PARENT compositor (games-on-whales lesson).
  # Without this override a Wayland-capable Flatpak bypasses this session'"'"'s
  # Xwayland and maps its window as a sibling of the whole desktop: unmanaged by
  # xfwm4 and fighting the desktop for the stream.
  grep -q "flatpak override --user --nosocket=wayland" "$xfce"

  # Sizing (quasar#384): rootful Xwayland takes the session mode via -geometry
  # WxH (verified against xorg-x11-server-Xwayland 24.1.13 on Fedora 43:
  # "-geometry WxH  set Xwayland window size when rootful"). Nothing is baked as
  # ENV in the Dockerfile -- the precedence chain lives here.
  grep -q "QUASAR_XFCE_WIDTH:-\${QUASAR_STREAM_WIDTH:-1920}" "$xfce"
  grep -q "QUASAR_XFCE_HEIGHT:-\${QUASAR_STREAM_HEIGHT:-1080}" "$xfce"
  grep -q -- "-geometry" "$xfce"
  grep -q "dbus-run-session -- startxfce4" "$xfce"
  grep -q "/tmp/.X11-unix" "$xfce"

  # WAYLAND_DISPLAY MUST be unset for the session here -- the exact INVERSE of
  # verify-kde.sh, which fails if the KDE launcher unsets it. In quasar-kde the
  # nested Wayland client IS kwin, so it needs the parent socket for the whole
  # session lifetime. In quasar-xfce the nested client is the rootful Xwayland
  # (which gets the socket in its own environment), and XFCE is X11-only: every
  # session process is an X11 client of that Xwayland. If any of them found
  # WAYLAND_DISPLAY set, GTK/Qt/SDL would prefer Wayland and connect to the
  # PARENT compositor instead, mapping windows outside the session entirely.
  grep -q "^unset WAYLAND_DISPLAY$" "$xfce"

  # X11-only session pins.
  grep -q "export XDG_SESSION_TYPE=x11" "$xfce"
  grep -q "export XDG_CURRENT_DESKTOP=XFCE" "$xfce"
  grep -q "export DESKTOP_SESSION=xfce" "$xfce"
  grep -q "export GDK_BACKEND=x11" "$xfce"
  grep -q "export QT_QPA_PLATFORM=xcb" "$xfce"
  grep -q "export MOZ_ENABLE_WAYLAND=0" "$xfce"

  # No session mode may be baked as an image ENV (quasar#384): a baked
  # 1920x1080 silently downscales every non-1080p session.
  if env | grep -qE "^QUASAR_(XFCE|STREAM)_(WIDTH|HEIGHT|REFRESH|FPS)="; then
    echo "FAIL: a session mode is baked as an image ENV (quasar#384)" >&2
    exit 1
  fi

  # File capabilities on session binaries are fatal in a container started
  # without the matching --cap-add: Linux refuses execve with EPERM when a
  # file'"'"'s permitted set is not a subset of the process'"'"'s bounding set, and
  # the only symptom is a bare "Operation not permitted" (this is why
  # quasar-kde has to setcap -r kwin_wayland). This package set ships clean;
  # the assertion is what catches a package bump that reintroduces one.
  for b in /usr/bin/Xwayland /usr/bin/xfwm4 /usr/bin/xfce4-session \
           /usr/bin/xfce4-panel /usr/bin/xfdesktop /usr/bin/xfsettingsd; do
    capout="$(getcap "$b" || true)"
    if [[ -n "$capout" ]]; then
      echo "FAIL: $b carries a file capability ($capout); strip it with setcap -r in the Dockerfile" >&2
      exit 1
    fi
  done

  # xfce-polkit'"'"'s autostart must stay suppressed: its agent needs
  # systemd-logind, which this container does not have, and without this it
  # aborts and XFCE shows a "PolicyKitAgent" error dialog on every login.
  grep -q "^Hidden=true$" /etc/xdg/autostart/xfce-polkit.desktop

  # Baked default panel layout, shipped as an xfconf SYSTEM default so per-user
  # changes in $HOME still win.
  panel=/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml
  test -f "$panel"
  grep -q "value=\"whiskermenu\"" "$panel"
  # Branding: the Whisker menu button icon resolves to the Quasar mark through
  # the icon theme.
  grep -q "name=\"button-icon\" type=\"string\" value=\"quasar\"" "$panel"

  # Branding files themselves.
  test -f /usr/share/icons/hicolor/scalable/apps/quasar.svg
  test -f /usr/share/icons/hicolor/256x256/apps/quasar.png
  file /usr/share/icons/hicolor/256x256/apps/quasar.png | grep -q "PNG image data, 256 x 256"

  # Steam desktop client'"'"'s stock .desktop entry (shipped by the RPM) must
  # appear in the menu automatically -- no wrapper script, menu-launched only.
  test -f /usr/share/applications/steam.desktop
  # GUI store (see the Dockerfile store-decision comment).
  test -f /usr/share/applications/org.gnome.Software.desktop

  # Neither a screensaver nor a power manager is installed, so there is nothing
  # to blank or suspend a streamed session (and no defaults to bake).
  if command -v xfce4-screensaver >/dev/null 2>&1; then
    echo "FAIL: xfce4-screensaver present; a streamed session has no local display to blank" >&2
    exit 1
  fi
  if command -v xfce4-power-manager >/dev/null 2>&1; then
    echo "FAIL: xfce4-power-manager present; bake DPMS/display-off defaults or drop the package" >&2
    exit 1
  fi
'

labels="$(docker image inspect quasar-xfce:dev --format '{{json .Config.Labels}}')"
jq -e '.["org.quasar.image.contract"] == "1" and .["org.quasar.image.acceleration"] == "required" and .["org.quasar.image.persist"] == "/home/quasar" and .["org.quasar.image.session"] == "desktop" and .["org.opencontainers.image.title"] == "Quasar XFCE desktop"' <<<"$labels" >/dev/null

echo "quasar-xfce structural checks passed"
