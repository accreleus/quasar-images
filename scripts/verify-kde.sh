#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

for executable in startplasma-wayland kwin_wayland dbus-run-session flatpak steam bwrap quasar-kde xdg-user-dirs-update firefox; do
  docker run --rm --entrypoint /bin/bash quasar-kde:dev -lc "command -v $executable >/dev/null"
done

# gamescope must be ABSENT from this image (quasar-kde carries zero gamescope/
# BPM weight by construction -- it inherits from quasar-steam-runtime, not
# quasar-steam). NOTE: negative assertions must use explicit if/exit, not
# "! command -v ...". bash's errexit (set -e) does not fire on a command whose
# exit status is inverted by !, so "! command -v gamescope" would silently
# PASS (never even print a failure) if gamescope were reintroduced -- the same
# lesson verify-steam.sh's setsid/setpgid checks are built around.
if docker run --rm --entrypoint /bin/bash quasar-kde:dev -lc 'command -v gamescope' >/dev/null 2>&1; then
  echo "FAIL: gamescope present in quasar-kde:dev (this image must carry zero gamescope/BPM weight)" >&2
  exit 1
fi

docker run --rm --entrypoint /bin/bash quasar-kde:dev -lc '
  set -e
  kde=/usr/local/bin/quasar-kde

  # Launcher-owned graceful shutdown (quasar-images#1), same contract as the
  # Steam launcher: no setsid/setpgid/group-kill anywhere -- everything stays
  # in tini'"'"'s direct descendant tree, so there is no process group to kill and
  # no way to reproduce the 6551fe8 EPERM-FATAL.
  # NOTE: negative assertions must use explicit if/exit, not "! grep -q ...".
  # bash'"'"'s errexit (set -e) does not fire on a command whose exit status is
  # inverted by !, so "! grep -q ..." would silently PASS (never even print a
  # failure) if setsid/-g were reintroduced -- caught in review on verify-steam.sh.
  if grep -q "setsid" "$kde"; then
    echo "FAIL: setsid present in $kde" >&2
    exit 1
  fi
  if grep -q "setpgid" "$kde"; then
    echo "FAIL: setpgid present in $kde" >&2
    exit 1
  fi
  # Same EPERM-FATAL class as setsid/-g: a negative-pid kill (group-kill) or a
  # signal-named group-kill (kill -TERM -$pid) targets the whole process
  # group, which is EPERM under --cap-drop ALL/no CAP_KILL against a reshaped
  # group -- must never be reintroduced.
  if grep -qE '"'"'kill[^|]* -- -|kill -[A-Z]+ -[0-9$]'"'"' "$kde"; then
    echo "FAIL: group-kill (negative-pid kill) present in $kde" >&2
    exit 1
  fi
  grep -q "trap on_term TERM INT" "$kde"
  grep -q "QUASAR_KDE_SHUTDOWN_TIMEOUT:-8" "$kde"
  grep -q "QUASAR_KDE_COMPOSITOR_TIMEOUT:-30" "$kde"
  grep -q "flatpak remote-add --user --if-not-exists flathub" "$kde"
  # Flatpak/Discover usable at all (2026-08-15): the empty SYSTEM installation
  # must exist or every flatpak call -- and Discover's flatpak backend -- fails
  # "opening repo: opendir(/var/lib/flatpak/repo)"; the fwupd Discover backend
  # must be gone (no firmware in a container, only error dialogs); kscreen must
  # be present or there is no Display/scaling settings page.
  test -f /var/lib/flatpak/repo/config
  test ! -e /usr/lib64/qt6/plugins/discover/fwupd-backend.so
  test -f /usr/lib64/qt6/plugins/discover/flatpak-backend.so
  test -f /usr/share/applications/kcm_kscreen.desktop
  grep -q "xdg-user-dirs-update" "$kde"
  grep -q "/run/quasar/share" "$kde"

  # The black-stream fix (live-diagnosed on the dev box 2026-08-13): without
  # KWIN_USE_OVERLAYS=0 kwin offloads every window to a wl_subsurface and
  # leaves its root output surface a single opaque black pixel forever -- the
  # session looks completely healthy in-container (kwin up, Xwayland up,
  # plasmashell up) and the failure is only visible in the encoded stream
  # (LUMA mean=0.0). No in-container smoke test catches its absence, so this
  # assertion is the only thing standing between a future edit and a silent
  # re-black of the stream.
  grep -q "KWIN_USE_OVERLAYS=0" "$kde"

  grep -q "dbus-run-session -- startplasma-wayland" "$kde"

  # WAYLAND_DISPLAY must NOT be unset by this launcher -- the exact inverse of
  # the Steam launcher'"'"'s assertion. quasar-steam unsets it once gamescope hands
  # its clients a *new* socket; here kwin_wayland IS the client and needs the
  # parent compositor socket for the whole session lifetime (nested-on-Wayland),
  # so unsetting it would sever kwin from its only compositor. Explicit
  # if/exit (not "! grep -q ...") for the same set -e reason as the negative
  # checks above.
  if grep -q "unset WAYLAND_DISPLAY" "$kde"; then
    echo "FAIL: unset WAYLAND_DISPLAY present in $kde (kwin needs it for the whole nested session)" >&2
    exit 1
  fi

  # Sizing shim (quasar#384): PATH-shadowing kwin_wayland wrapper is the only
  # way to get the session'"'"'s mode onto the nested kwin output on Plasma 6.7.
  shim=/usr/local/libexec/quasar-kde/kwin_wayland
  test -x "$shim"
  grep -q "exec /usr/bin/kwin_wayland" "$shim"
  grep -q "/usr/local/libexec/quasar-kde" "$kde"

  # kwin'"'"'s cap_sys_nice=ep FILE capability must be stripped (setcap -r in the
  # Dockerfile). Linux refuses execve with EPERM when a file'"'"'s permitted
  # capability set is not a subset of the process'"'"'s bounding set, so with the
  # file cap in place kwin_wayland cannot be exec'"'"'d AT ALL in a container
  # started without --cap-add SYS_NICE. getcap must report nothing.
  capout="$(getcap /usr/bin/kwin_wayland || true)"
  if [[ -n "$capout" ]]; then
    echo "FAIL: /usr/bin/kwin_wayland still carries a file capability ($capout); setcap -r missing from the Dockerfile" >&2
    exit 1
  fi

  # Baked Plasma defaults for a container-streamed session (no local display
  # to lock/dim/suspend; per-user config in $HOME still wins).
  grep -q "Autolock=false" /etc/xdg/kscreenlockerrc
  grep -q "Indexing-Enabled=false" /etc/xdg/baloofilerc
  grep -q "Enabled=false" /etc/xdg/kwalletrc

  # Branding: Quasar mark as the Kickoff/application icon.
  test -f /usr/share/icons/hicolor/scalable/apps/quasar.svg
  test -f /usr/share/icons/hicolor/256x256/apps/quasar.png
  file /usr/share/icons/hicolor/256x256/apps/quasar.png | grep -q "PNG image data, 256 x 256"

  # Kickoff default-icon hook: Fedora'"'"'s plasmoidsetupscripts file is what
  # actually runs on Kickoff-applet creation (the design-spec'"'"'s assumed
  # plasma/shells/.../layout.js does not exist on Plasma 6.7.4 / Fedora 43 --
  # verified empirically on the dev box). Guards against a kde-settings
  # package bump silently reverting the branding.
  kickoff=/usr/share/plasma/look-and-feel/org.fedoraproject.fedora.desktop/contents/plasmoidsetupscripts/org.kde.plasma.kickoff.js
  grep -q "writeConfig(\"icon\", \"quasar\")" "$kickoff"

  # Steam desktop client'"'"'s stock .desktop entry (shipped by the RPM) must
  # appear in Kickoff automatically -- no wrapper script, menu-launched only.
  test -f /usr/share/applications/steam.desktop
'

labels="$(docker image inspect quasar-kde:dev --format '{{json .Config.Labels}}')"
jq -e '.["org.quasar.image.contract"] == "1" and .["org.quasar.image.acceleration"] == "required" and .["org.quasar.image.persist"] == "/home/quasar" and .["org.quasar.image.session"] == "desktop"' <<<"$labels" >/dev/null

echo "quasar-kde structural checks passed"
