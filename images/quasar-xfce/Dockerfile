ARG STEAM_RUNTIME_IMAGE=quasar-steam-runtime:dev
FROM ${STEAM_RUNTIME_IMAGE}

ARG VERSION=0.1.0-dev
LABEL org.opencontainers.image.title="Quasar XFCE desktop" \
      org.quasar.image.contract="1" \
      org.quasar.image.family="fedora" \
      org.quasar.image.base.version="${VERSION}" \
      org.quasar.image.acceleration="required" \
      org.quasar.image.graphics-apis="vulkan,egl,opengl" \
      org.quasar.image.entrypoint="/usr/local/bin/quasar-entrypoint" \
      org.quasar.image.persist="/home/quasar" \
      org.quasar.image.session="desktop"

# Session: xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-settings xfconf,
# plus xorg-x11-server-Xwayland (NOT inherited -- quasar-steam-runtime has no
# X server; verified on the dev box) and dbus-x11 for dbus-launch/dbus-run-session
# against an X11 session. Apps: xfce4-terminal thunar xfce4-taskmanager mousepad.
# Menu: xfce4-whiskermenu-plugin. Flatpak: flatpak (NOT inherited) + gnome-software
# as the GUI store. Fonts: google-noto-sans-fonts google-noto-emoji-fonts
# google-noto-sans-mono-fonts. xdg-user-dirs for first-run $HOME layout.
# at-spi2-core is already inherited from quasar-app.
#
# STORE DECISION (measured on the dev box against quasar-steam-runtime:dev,
# Fedora 43, weak deps off): the XFCE session set alone resolves to 118 packages
# / 207 MiB installed; adding gnome-software takes it to 144 packages / 397 MiB,
# i.e. +26 packages / +190 MiB. That is under the 300 MiB budget agreed for a
# GUI store, and gnome-software ships its Flatpak backend in the main package
# (/usr/lib64/gnome-software/plugins-23/libgs_plugin_flatpak.so), so no extra
# plugin subpackage is needed. XFCE has no native Flatpak-capable store of its
# own (there is no Discover equivalent), so gnome-software is included.
#
# EXCLUDED deliberately: xfce4-power-manager and xfce4-screensaver (neither is
# pulled in as a hard dependency of this set -- verified with rpm -q on the dev
# box -- so there is nothing to disable and no DPMS/blank defaults to bake),
# xscreensaver, NetworkManager applets, gnome-keyring, the docklike panel plugin
# and xfce4-pulseaudio-plugin (audio is captured by the node-agent, not mixed by
# a tray applet). Lean-image principle: weak deps off, no docs, dnf cache
# cleaned in-layer.
RUN dnf --setopt=install_weak_deps=False --setopt=tsflags=nodocs -y install \
      xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-settings xfconf \
      xorg-x11-server-Xwayland dbus-x11 \
      xfce4-terminal thunar xfce4-taskmanager mousepad \
      xfce4-whiskermenu-plugin \
      flatpak gnome-software \
      google-noto-sans-fonts google-noto-emoji-fonts google-noto-sans-mono-fonts \
      xdg-user-dirs \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# xfce-polkit is pulled in as a hard dependency of this set. Its authentication
# agent calls polkit_unix_session_new_for_process_sync() at startup, which needs
# systemd-logind; quasar-entrypoint is a plain PID-1 chain with no logind, so the
# agent aborts with
#   CRITICAL: polkit_agent_listener_register_with_options:
#             assertion 'POLKIT_IS_SUBJECT (subject)' failed
# and XFCE shows a user-visible "PolicyKitAgent" error dialog on every login.
# A streamed session has no interactive privilege prompts to serve, so the
# autostart entry is suppressed (games-on-whales applies the identical fix in
# apps/xfce/build-fedora/Dockerfile). `test -f` first so that a future package
# set without xfce-polkit fails the build LOUDLY instead of silently creating a
# bogus autostart file with nothing but Hidden=true in it.
RUN test -f /etc/xdg/autostart/xfce-polkit.desktop \
    && printf '\nHidden=true\n' >> /etc/xdg/autostart/xfce-polkit.desktop

# Baked default panel layout: one bottom panel whose Whisker menu button carries
# the Quasar mark. Shipped under /etc/xdg so xfconfd treats it as a read-only
# system default and anything the user changes in $HOME still wins. Full
# rationale (including why this beats /etc/xdg/xfce4/panel/default.xml) is in
# the file header.
COPY images/quasar-xfce/overlay/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml

# Branding: Quasar mark as the Whisker menu / application icon (scalable + 256px
# raster fallback), same hicolor paths and same source files as quasar-kde.
COPY images/quasar-xfce/overlay/usr/share/icons/hicolor/scalable/apps/quasar.svg /usr/share/icons/hicolor/scalable/apps/quasar.svg
COPY images/quasar-xfce/overlay/usr/share/icons/hicolor/256x256/apps/quasar.png /usr/share/icons/hicolor/256x256/apps/quasar.png

COPY images/quasar-xfce/quasar-xfce /usr/local/bin/quasar-xfce

RUN chmod 0644 /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml \
      /usr/share/icons/hicolor/scalable/apps/quasar.svg \
      /usr/share/icons/hicolor/256x256/apps/quasar.png \
    && chmod 0755 /usr/local/bin/quasar-xfce \
    && gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true

# NO setcap -r step here, unlike quasar-kde. Linux refuses execve with EPERM when
# a file's permitted capability set is not a subset of the process's bounding
# set, so any file capability on a session binary is fatal in a container started
# without the matching --cap-add (that is why quasar-kde has to strip kwin's
# cap_sys_nice=ep). Checked on the dev box against this exact package set:
# getcap reports NOTHING for /usr/bin/Xwayland, xfwm4, xfce4-session,
# xfce4-panel, xfdesktop, startxfce4 and xfsettingsd, so there is nothing to
# strip. scripts/verify-xfce.sh asserts that stays true across package bumps.

CMD ["/usr/local/bin/quasar-xfce"]
