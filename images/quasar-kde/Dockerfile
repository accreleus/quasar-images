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
# konsole dolphin. Flatpak: flatpak plasma-discover plasma-discover-flatpak.
# Fonts: google-noto-sans-fonts google-noto-emoji-fonts
# google-noto-sans-mono-fonts. xdg-user-dirs for first-run $HOME layout.
# Lean-image principle: weak deps off, no docs, dnf cache cleaned in-layer.
# No SDDM/NetworkManager applets/akonadi-PIM/kwallet integration are
# installed; baloo-file-extractor is not requested here, but if it lands as
# a hard dependency of plasma-desktop it stays installed and is disabled via
# baloofilerc below (see overlay/etc/xdg/baloofilerc) rather than force-removed.
RUN dnf --setopt=install_weak_deps=False --setopt=tsflags=nodocs -y install \
      plasma-desktop plasma-workspace-wayland kwin xdg-desktop-portal-kde \
      konsole dolphin \
      flatpak plasma-discover plasma-discover-flatpak \
      google-noto-sans-fonts google-noto-emoji-fonts google-noto-sans-mono-fonts \
      xdg-user-dirs \
    && dnf clean all \
    && rm -rf /var/cache/dnf

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

RUN chmod 0644 /etc/xdg/kscreenlockerrc /etc/xdg/baloofilerc /etc/xdg/kwalletrc \
      /usr/share/icons/hicolor/scalable/apps/quasar.svg \
      /usr/share/icons/hicolor/256x256/apps/quasar.png \
      /usr/share/plasma/look-and-feel/org.fedoraproject.fedora.desktop/contents/plasmoidsetupscripts/org.kde.plasma.kickoff.js \
    && chmod 0755 /usr/local/bin/quasar-kde

CMD ["/usr/local/bin/quasar-kde"]
