ARG STEAM_RUNTIME_IMAGE=quasar-steam-runtime:dev

# WHERE THE PATCHED KWIN RPMS COME FROM.
#
#   KWIN_RPMS_IMAGE=kwin-rpms                        (default) build them here
#   KWIN_RPMS_IMAGE=ghcr.io/<owner>/quasar-kwin-rpms:<tag>     pull the artefact
#
# `FROM ${KWIN_RPMS_IMAGE} AS kwin-artifact` resolves against this file's stage
# names FIRST, so the default names the local `kwin-rpms` stage and the build is
# exactly what it always was. Anything else is a registry reference, and BuildKit
# only instantiates the stages a target needs -- so pointing this at a published
# artefact means the 27-minute rpmbuild below is never run.
#
# 27 minutes is not an estimate: run 31920375541 logged `[kwin-build 4/4] …
# DONE 1613.4s`, out of 2098s for the whole image hierarchy. Runs that touch no
# kwin input take 5-8 minutes total. Paying the 27 minutes on a benchapp change
# is the single largest avoidable cost in this repo's CI.
#
# <tag> is scripts/kwin-artifact-tag.sh: a content hash over KWIN_NVR, every
# kwin/*.patch, and build-kwin.sh. Nothing else invalidates it.
ARG KWIN_RPMS_IMAGE=kwin-rpms

# Exact kwin source package the patch is written against. PINNED, not "whatever
# dnf has today": a Fedora kwin update needs the patch re-diffed (see the README,
# "Patched KWin (nested mode ladder)"), and a floating version would apply the
# patch to a moving target and fail -- or worse, apply with fuzz. Bumping this
# ARG is the deliberate act that says "the re-diff was done".
ARG KWIN_NVR=6.7.4-1.fc43

# --- Patched KWin ------------------------------------------------------------
# Fedora's kwin, rebuilt with images/quasar-kde/kwin/*.patch, so the NESTED
# wayland backend advertises a real mode ladder and applies a resolution picked
# in System Settings -> Display. Upstream's nested backend synthesises exactly
# one mode from the host's xdg_toplevel.configure size and ignores
# OutputConfiguration::currentMode entirely (and its scale), so the Display KCM
# is inert inside a Quasar session -- see kwin/0001-nested-backend-mode-ladder.patch
# (resolution) and kwin/0002-nested-backend-kscreen-scale.patch (scale) for the
# full problem statements, and the README section "Patched KWin (nested mode
# ladder)" for the recurring re-diff cost on a Fedora kwin update.
#
# Every kwin/*.patch is copied in and applied in sorted order by build-kwin.sh.
#
# This stage is DISCARDED and its RPMs are never copied into a layer -- the
# install below bind-mounts them instead -- so neither the ~1.5 GB of build
# dependencies nor the RPMs themselves reach the shipped image (measured: the
# bind-mount saves 11.9 MB over a COPY, which a later rm could not reclaim).
#
# Base is pinned to the same Fedora release the runtime family is built from --
# an RPM built against a different release would not be interchangeable with the
# kwin it replaces.
FROM fedora:43 AS kwin-build
ARG KWIN_NVR
ENV QUASAR_KWIN_NVR=${KWIN_NVR}
COPY images/quasar-kde/kwin/*.patch /tmp/kwin-patches/
COPY images/quasar-kde/kwin/build-kwin.sh /usr/local/bin/build-kwin.sh
RUN chmod 0755 /usr/local/bin/build-kwin.sh && /usr/local/bin/build-kwin.sh

# The PUBLISHABLE artefact: the RPMs and nothing else. FROM scratch, so what gets
# pushed to GHCR is ~12 MB of packages rather than a 200 MB Fedora rootfs that
# happens to have some RPMs in it. It has no shell and no entrypoint on purpose --
# it is a file bundle, not an image anyone should run.
#
# Build and publish it with:  ./scripts/build.sh quasar-kwin-rpms
FROM scratch AS kwin-rpms
ARG KWIN_NVR
LABEL org.opencontainers.image.title="Quasar patched KWin RPMs" \
      org.quasar.kwin.nvr="${KWIN_NVR}.quasar1" \
      org.quasar.artifact="kwin-rpms"
# build-kwin.sh's own default output dir, left alone deliberately: overriding it
# with QUASAR_KWIN_RPM_DIR would change the builder RUN's cache key and force a
# 27-minute rebuild on every box that already has the old one cached, for no
# reason other than a tidier path.
COPY --from=kwin-build /tmp/kwin-rpms /kwin-rpms

# Resolves to the local stage above, or to a published artefact. The alias keeps
# the bind mount below referring to one stable name either way.
FROM ${KWIN_RPMS_IMAGE} AS kwin-artifact

FROM ${STEAM_RUNTIME_IMAGE}

ARG VERSION=0.1.0-dev
ARG KWIN_NVR
LABEL org.opencontainers.image.title="Quasar KDE Plasma desktop" \
      org.quasar.kde.kwin="${KWIN_NVR}.quasar1" \
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
# display scaling from inside the session (operator report 2026-08-15). With
# the patched kwin installed below the resolution list is a real ladder too
# (it used to be a single entry = the streamed resolution, quasar#384).
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

# Install the patched kwin over the distro package. Same N-V-R plus a .quasar1
# %dist suffix, so this is an ordinary upgrade of the same package, not a
# replacement by a different one -- every other Plasma package's `Requires:
# kwin = 6.7.4-1.fc43` style dependency still resolves.
#
# ONLY the subpackages already installed above are upgraded. `install *.rpm`
# would drag in every subpackage the SRPM produces (kwin-x11, -devel, ...) and
# silently fatten the image with things the session never runs; kwin's
# subpackages are mutually version-locked, so a partial set that does NOT match
# what is installed would break deps -- hence the explicit intersection.
# --allowerasing covers a subpackage split changing between Fedora rebuilds
# (dnf5 wants it AFTER the subcommand).
#
# The RPMs are BIND-MOUNTED from the builder stage rather than COPYed: a COPY
# would persist the packages in a layer forever (11.9 MB, measured), and a
# `rm -rf` in a later layer cannot reclaim it. Nothing from the builder stage
# ends up in the image.
RUN --mount=type=bind,from=kwin-artifact,source=/kwin-rpms,target=/tmp/kwin-rpms \
    set -eu; \
    installed="$(rpm -qa --qf '%{NAME}\n' 'kwin*' | sort -u)"; \
    test -n "$installed"; \
    rpms=""; \
    for name in $installed; do \
      for rpm in /tmp/kwin-rpms/*.rpm; do \
        if [ "$(rpm -qp --qf '%{NAME}' "$rpm" 2>/dev/null)" = "$name" ]; then rpms="$rpms $rpm"; fi; \
      done; \
    done; \
    test -n "$rpms"; \
    echo "upgrading to patched kwin:$rpms"; \
    dnf -y --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
      install --allowerasing $rpms; \
    rpm -q kwin | grep -q '\.quasar'; \
    dnf clean all; \
    rm -rf /var/cache/dnf

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
