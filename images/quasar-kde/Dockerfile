ARG STEAM_RUNTIME_IMAGE=quasar-steam-runtime:dev
FROM ${STEAM_RUNTIME_IMAGE}

ARG VERSION=0.1.0-dev
LABEL org.opencontainers.image.title="Quasar KDE Plasma desktop" \
      org.quasar.image.contract="1" \
      org.quasar.image.family="fedora" \
      org.quasar.image.base.version="${VERSION}" \
      org.quasar.image.acceleration="required" \
      org.quasar.image.graphics-apis="vulkan,egl,opengl" \
      org.quasar.image.entrypoint="/usr/local/bin/quasar-entrypoint" \
      org.quasar.image.persist="/home/quasar" \
      org.quasar.image.session="desktop"

# Session: plasma-desktop plasma-workspace-wayland kwin (dbus-daemon already
# inherited from quasar-steam-runtime). Portal: xdg-desktop-portal-kde. Apps:
# kscreen: the Display Configuration KCM (System Settings -> Display) — the
# scaling and per-output settings UI; without it there is no way to change
# display scaling from inside the session (operator report 2026-08-15). The
# nested output offers a single mode = the streamed resolution (quasar#384),
# so the resolution list is one entry by design; scaling is what this buys.
# konsole dolphin firefox (a desktop without a browser gives the user no way
# to even confirm networking works — operator request 2026-08-14; native
# package, not a flatpak, so it exists before any per-home flatpak state and
# runs Wayland-native out of the box).
# Flatpak: flatpak plasma-discover plasma-discover-flatpak.
# Fonts: google-noto-sans-fonts google-noto-emoji-fonts
# google-noto-sans-mono-fonts. xdg-user-dirs for first-run $HOME layout.
# Lean-image principle: weak deps off, no docs, dnf cache cleaned in-layer.
# No SDDM/NetworkManager applets/akonadi-PIM/kwallet integration are
# installed; baloo-file-extractor is not requested here, but if it lands as
# a hard dependency of plasma-desktop it stays installed and is disabled via
# baloofilerc below (see overlay/etc/xdg/baloofilerc) rather than force-removed.
RUN dnf --setopt=install_weak_deps=False --setopt=tsflags=nodocs -y install \
      plasma-desktop plasma-workspace-wayland kwin xdg-desktop-portal-kde \
      konsole dolphin firefox \
      flatpak plasma-discover plasma-discover-flatpak \
      kscreen \
      google-noto-sans-fonts google-noto-emoji-fonts google-noto-sans-mono-fonts \
      xdg-user-dirs \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Two post-install fixups (live-verified 2026-08-15):
# 1. Discover ships a firmware (fwupd) backend as a hard dependency; there is
#    no firmware to manage inside a container and the backend only produces
#    "Update Issue" errors on every launch. Remove the plugin, keep the package
#    (removing fwupd would take plasma-discover with it).
# 2. Flatpak refuses EVERY operation, including user-scope ones, until the
#    SYSTEM installation dir exists: "While opening repository
#    /var/lib/flatpak/repo: opening repo: opendir(...): No such file or
#    directory". Discover's flatpak backend hits the same error and reports
#    "Missing Backends" even though the launcher already added the user-scope
#    Flathub remote. Any --system query as root initialises the empty repo; it
#    stays empty -- installs go to the user scope in the persistent $HOME
#    (unprivileged, no polkit/system-helper needed).
RUN rm -f /usr/lib64/qt6/plugins/discover/fwupd-backend.so \
    && flatpak remotes --system >/dev/null \
    && test -f /var/lib/flatpak/repo/config

# Baked Plasma defaults for a container-streamed session (no local display to
# lock/dim/suspend; per-user config in $HOME still wins if a user changes it).
COPY images/quasar-kde/overlay/etc/xdg/kscreenlockerrc /etc/xdg/kscreenlockerrc
COPY images/quasar-kde/overlay/etc/xdg/baloofilerc /etc/xdg/baloofilerc
COPY images/quasar-kde/overlay/etc/xdg/kwalletrc /etc/xdg/kwalletrc

# Branding: Quasar mark as the Kickoff/application icon (scalable + 256px
# raster fallback), plus a Quasar-modified copy of Fedora's Kickoff plasmoid
# setup script so a fresh $HOME's Kickoff applet defaults to it. NOTE: the
# spec's assumed path
# /usr/share/plasma/shells/org.kde.plasma.desktop/contents/layout.js does not
# exist on this build (Plasma 6.7.4 / kde-settings-43.101 / Fedora 43) --
# verified empirically on the dev box. The real hook Fedora's
# org.fedoraproject.fedora.desktop look-and-feel package runs on Kickoff
# creation is this plasmoidsetupscripts file; see the header comment in the
# overlay file for the full trace.
COPY images/quasar-kde/overlay/usr/share/icons/hicolor/scalable/apps/quasar.svg /usr/share/icons/hicolor/scalable/apps/quasar.svg
COPY images/quasar-kde/overlay/usr/share/icons/hicolor/256x256/apps/quasar.png /usr/share/icons/hicolor/256x256/apps/quasar.png
COPY images/quasar-kde/overlay/usr/share/plasma/look-and-feel/org.fedoraproject.fedora.desktop/contents/plasmoidsetupscripts/org.kde.plasma.kickoff.js /usr/share/plasma/look-and-feel/org.fedoraproject.fedora.desktop/contents/plasmoidsetupscripts/org.kde.plasma.kickoff.js

COPY images/quasar-kde/quasar-kde /usr/local/bin/quasar-kde

# PATH-shadowing kwin_wayland wrapper: the ONLY way to get the session's mode
# onto the nested kwin output on Plasma 6.7 (kwin_wayland_wrapper spawns the
# compositor by bare name and forwards no size). Deliberately NOT in
# /usr/local/bin -- quasar-kde prepends this directory to PATH for the session
# only. Full rationale in both files.
COPY images/quasar-kde/kwin_wayland /usr/local/libexec/quasar-kde/kwin_wayland

RUN chmod 0644 /etc/xdg/kscreenlockerrc /etc/xdg/baloofilerc /etc/xdg/kwalletrc \
      /usr/share/icons/hicolor/scalable/apps/quasar.svg \
      /usr/share/icons/hicolor/256x256/apps/quasar.png \
      /usr/share/plasma/look-and-feel/org.fedoraproject.fedora.desktop/contents/plasmoidsetupscripts/org.kde.plasma.kickoff.js \
    && chmod 0755 /usr/local/bin/quasar-kde /usr/local/libexec/quasar-kde/kwin_wayland

# Strip kwin's cap_sys_nice=ep FILE capability (same fix games-on-whales applies
# to sway: `setcap -r /usr/sbin/sway` in their base-app image). Linux refuses
# execve with EPERM when a file's permitted capability set is not a subset of
# the process's bounding set, so with the file cap in place kwin_wayland cannot
# be exec'd AT ALL in a container started without `--cap-add SYS_NICE` -- the
# only symptom is a bare "Operation not permitted". Verified on the dev box
# 2026-08-13: `kwin_wayland --help` fails that way without the cap and succeeds
# with it. CAP_SYS_NICE is OPTIONAL in the Quasar contract (quasar-base's
# ambient grant is deliberately conditional -- see 9bb58d9 -- because older
# node-agents don't pass it), so the file cap is redundant where the cap exists
# (the entrypoint's ambient grant is inherited across exec) and fatal where it
# does not. setcap ships in the inherited libcap; no extra package needed.
RUN setcap -r /usr/bin/kwin_wayland

CMD ["/usr/local/bin/quasar-kde"]
