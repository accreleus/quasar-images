#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

for executable in startplasma-wayland kwin_wayland dbus-run-session flatpak steam bwrap quasar-kde xdg-user-dirs-update firefox; do
  docker run --rm --entrypoint /bin/bash quasar-kde:dev -lc "command -v $executable >/dev/null"
done

# --- Patched KWin (nested mode ladder) --------------------------------------
# The image MUST run the kwin rebuilt from images/quasar-kde/kwin/*.patch, not
# Fedora's stock kwin: without the patch the nested backend advertises a single
# output mode and ignores OutputConfiguration::currentMode, so System Settings ->
# Display cannot change the session's internal resolution at all. A base-image
# refresh that pulls a newer distro kwin would silently undo this, and the only
# symptom is a Display KCM that quietly does nothing -- hence a hard assertion
# rather than a comment. Re-diff instructions: README, "Patched KWin (nested
# mode ladder)".
build_context_patch="images/quasar-kde/kwin/0001-nested-backend-mode-ladder.patch"
if [[ ! -s "$build_context_patch" ]]; then
  echo "FAIL: $build_context_patch is missing or empty in the build context" >&2
  exit 1
fi
grep -q "src/backends/wayland/wayland_output.cpp" "$build_context_patch"
grep -q "src/backends/wayland/wayland_display.cpp" "$build_context_patch"
# 0002 is what makes the Display KCM's SCALE slider work under a host that
# implements wp_fractional_scale_v1 -- which Quasar's compositor does, so
# without it the slider is inert in exactly the environment that matters.
scale_patch="images/quasar-kde/kwin/0002-nested-backend-kscreen-scale.patch"
if [[ ! -s "$scale_patch" ]]; then
  echo "FAIL: $scale_patch is missing or empty in the build context" >&2
  exit 1
fi
grep -q "src/backends/wayland/wayland_output.cpp" "$scale_patch"
if [[ ! -x images/quasar-kde/kwin/build-kwin.sh ]]; then
  echo "FAIL: images/quasar-kde/kwin/build-kwin.sh is missing or not executable" >&2
  exit 1
fi
grep -q "FROM fedora:43 AS kwin-build" images/quasar-kde/Dockerfile

kwin_nvr="$(docker run --rm --entrypoint /bin/bash quasar-kde:dev -lc 'rpm -q kwin')"
if [[ "$kwin_nvr" != *".quasar"* ]]; then
  echo "FAIL: quasar-kde:dev runs an UNPATCHED kwin ($kwin_nvr); expected a .quasar release marker" >&2
  echo "      the nested mode ladder / Display Settings resolution change will not work" >&2
  exit 1
fi
echo "patched kwin present: $kwin_nvr"

# The org.quasar.kde.kwin label records WHICH kwin was patched, so a deployed
# image can be identified without running it. It must agree with what is
# actually installed, otherwise the label is worse than no label at all.
kwin_label="$(docker image inspect quasar-kde:dev --format '{{index .Config.Labels "org.quasar.kde.kwin"}}')"
if [[ -z "$kwin_label" || "$kwin_label" == "<no value>" ]]; then
  echo "FAIL: org.quasar.kde.kwin label missing from quasar-kde:dev" >&2
  exit 1
fi
# rpm -q prints kwin-<version>-<release>.<arch>; the label is <version>-<release>.
if [[ "$kwin_nvr" != "kwin-${kwin_label}."* ]]; then
  echo "FAIL: org.quasar.kde.kwin label ($kwin_label) does not match the installed kwin ($kwin_nvr)" >&2
  exit 1
fi
echo "kwin label agrees with the installed package: $kwin_label"

# The builder stage must not have leaked into the shipped image.
docker run --rm --entrypoint /bin/bash quasar-kde:dev -lc '
  set -e
  if [[ -e /tmp/kwin-rpms ]]; then
    echo "FAIL: /tmp/kwin-rpms left behind in the shipped image" >&2
    exit 1
  fi
  if command -v rpmbuild >/dev/null 2>&1; then
    echo "FAIL: rpmbuild present in the shipped image (kwin build stage leaked)" >&2
    exit 1
  fi
'

# FUNCTIONAL smoke: the assertions above only prove a .quasar-tagged kwin is
# installed, not that the patch still does anything. A re-diff that applies with
# fuzz, or a hunk silently dropped, would sail past them -- and the failure mode
# is a Display KCM that quietly does nothing, which nobody notices for weeks.
# So: actually run a nested session and change its resolution.
#
# Two kwins are needed. --virtual alone exercises the VIRTUAL backend, which was
# never broken and is not what the patch touches; the patched code only runs when
# kwin is a Wayland CLIENT of another compositor. So an outer --virtual kwin
# plays the host and the inner one is the nested session under test.
# Hard time-box: every wait is bounded and the container is --rm.
echo "running the nested mode-ladder + scale smoke (time-boxed)"
smoke="$(docker run --rm --entrypoint /bin/bash quasar-kde:dev -c '
  export XDG_RUNTIME_DIR=/tmp/rt HOME=/tmp/h
  mkdir -p "$XDG_RUNTIME_DIR" "$HOME"; chmod 0700 "$XDG_RUNTIME_DIR"
  export KWIN_COMPOSE=Q QT_FORCE_STDERR_LOGGING=1

  wait_socket() { for _ in $(seq 24); do [ -e "$XDG_RUNTIME_DIR/$1" ] && return 0; sleep 0.25; done; return 1; }

  dbus-daemon --session --fork --print-address=1 > /tmp/busA
  DBUS_SESSION_BUS_ADDRESS="$(head -1 /tmp/busA)" \
    kwin_wayland --virtual --width 1920 --height 1080 --socket=wl-host >/tmp/host.log 2>&1 &
  wait_socket wl-host || { echo "SMOKE-FAIL: host compositor never came up"; exit 1; }
  sleep 3

  dbus-daemon --session --fork --print-address=1 > /tmp/busB
  WAYLAND_DISPLAY=wl-host DBUS_SESSION_BUS_ADDRESS="$(head -1 /tmp/busB)" \
    kwin_wayland --width 1920 --height 1080 --socket=wl-nested >/tmp/nested.log 2>&1 &
  wait_socket wl-nested || { echo "SMOKE-FAIL: nested compositor never came up"; exit 1; }
  sleep 4

  export WAYLAND_DISPLAY=wl-nested
  modes=$(kscreen-doctor -o 2>/dev/null | sed -n "s/.*Modes: //p" | tr -d "\033" | sed "s/\[[0-9;]*m//g")
  count=$(printf "%s" "$modes" | grep -oE "[0-9]+x[0-9]+@" | wc -l)
  echo "MODES=$count"
  if [ "$count" -lt 2 ]; then
    echo "SMOKE-FAIL: nested output advertises $count mode(s); the patch is not taking effect"
    exit 1
  fi

  kscreen-doctor output.1.mode.1280x720@60 >/dev/null 2>&1
  sleep 2
  geom=$(kscreen-doctor -o 2>/dev/null | sed -n "s/.*Geometry: //p" | sed "s/\[[0-9;]*m//g" | head -1)
  echo "GEOMETRY=$geom"
  case "$geom" in
    *"0,0 1280x720"*) : ;;
    *) echo "SMOKE-FAIL: applying 1280x720 left the output at [$geom]"; exit 1 ;;
  esac

  # 0002: the SCALE slider. The host here is kwin_wayland --virtual, which DOES
  # implement wp_fractional_scale_v1 -- the same situation as Quasar, and the
  # exact case 0001 refused to apply a scale in.
  #
  # Assert on the LOGICAL geometry, not on the reported scale: 1280x720 at
  # scale 1.5 is an 854x480 desktop (kwin rounds the logical size UP), and the
  # mode must NOT have moved -- the buffer the host sees stays 1280x720, which is
  # what keeps the streamed resolution pinned.
  kscreen-doctor output.1.scale.1.5 >/dev/null 2>&1
  sleep 2
  sgeom=$(kscreen-doctor -o 2>/dev/null | sed -n "s/.*Geometry: //p" | sed "s/\[[0-9;]*m//g" | head -1)
  smode=$(kscreen-doctor -o 2>/dev/null | sed -n "s/.*Modes: //p" | tr -d "\033" | sed "s/\[[0-9;]*m//g" | grep -oE "[0-9]+x[0-9]+@[0-9.]+\*" | head -1)
  echo "SCALED-GEOMETRY=$sgeom"
  echo "SCALED-CURRENT-MODE=$smode"
  case "$sgeom" in
    *"0,0 854x480"*) : ;;
    *) echo "SMOKE-FAIL: scale 1.5 over a 1280x720 mode left the desktop at [$sgeom], expected 854x480"; exit 1 ;;
  esac
  case "$smode" in
    1280x720@*) : ;;
    *) echo "SMOKE-FAIL: setting the scale moved the current MODE to [$smode]; it must stay 1280x720"; exit 1 ;;
  esac
  echo "SMOKE-OK"
' 2>&1)" || { echo "$smoke" >&2; echo "FAIL: nested mode-ladder smoke failed" >&2; exit 1; }
printf '%s\n' "$smoke" | grep -E '^(MODES|GEOMETRY|SCALED-GEOMETRY|SCALED-CURRENT-MODE|SMOKE-OK)'
grep -q 'SMOKE-OK' <<<"$smoke"

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
  # must exist or every flatpak call -- and the Discover flatpak backend -- fails
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
