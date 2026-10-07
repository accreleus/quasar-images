ARG APP_IMAGE=quasar-app:dev
ARG STEAM_RUNTIME_IMAGE=quasar-steam-runtime:dev

# Gamescope with the nested-pointer-warp patch: upstream 3.16.23 (matching the
# Fedora 43 package) routes the parent compositor's absolute pointer into the
# touch path; Steam Big Picture asserts STEAM_TOUCH_CLICK_MODE=4 (Passthrough),
# which emits only wl_touch events that gamescope's Xwayland (started with
# -noTouchPointerEmulation) discards — mouse (and Steam's input latch) dead in
# BPM until a game launch. The one-argument patch makes Passthrough also warp
# the real cursor (wlserver_mousewarp), so nested pointer input works from
# session start.
#
# Direct display (quasar#453/#457): with QUASAR_DIRECT_DISPLAY=1 gamescope drives
# the monitor on its own DRM backend instead of nesting. On the NVIDIA driver its
# Vulkan-allocated scanout buffers corrupt the bottom of every 4K mode (upstream
# ValveSoftware/gamescope#2309); gamescope-gbm-scanout.patch allocates them with
# GBM instead, behind the ConVar drm_gbm_scanout, which the launcher sets only on
# that path. The lineage stays on 3.16.23 -- the patch is NightHammer1000's
# 3.16.25-based branch rebased here without code conflicts, while moving to
# 3.16.25 would mean re-proving the Quasar patches against a wlroots 0.19 bump.
# The one 3.16.24 piece the patch's switch relies on, ConVars read from
# gamescope_<name> environment variables, is backported unchanged as
# gamescope-convar-env-override.patch. Patch order matters: nested-pointer-warp,
# then convar-env-override, then gbm-scanout, which needs the env override for its
# switch. libgbm-devel makes HAVE_GBM=1; the build fails if it did not, rather
# than shipping a switch that does nothing.
# Xwayland-devel is wlroots' (a gamescope subproject) own build dependency.
# Builds from ${APP_IMAGE}, not the Steam runtime: the builder only needs the
# Fedora toolchain + `dnf builddep gamescope`, so keeping it on quasar-app
# leaves it independent of the runtime layer (and its build cache).
FROM ${APP_IMAGE} AS gamescope-builder

RUN dnf --setopt=install_weak_deps=False -y install \
      git meson ninja-build gcc gcc-c++ xorg-x11-server-Xwayland-devel mesa-libgbm-devel \
    && (dnf -y install dnf5-plugins || dnf -y install dnf-plugins-core) \
    && (dnf builddep -y gamescope || dnf builddep -y --enablerepo="*source*" gamescope) \
    && dnf clean all && rm -rf /var/cache/dnf

WORKDIR /build
COPY images/quasar-steam/gamescope-nested-pointer-warp.patch \
     images/quasar-steam/gamescope-convar-env-override.patch \
     images/quasar-steam/gamescope-gbm-scanout.patch /build/
RUN git clone --branch 3.16.23 --depth 1 --recurse-submodules https://github.com/ValveSoftware/gamescope.git \
    && cd gamescope \
    && git apply /build/gamescope-nested-pointer-warp.patch \
    && git apply /build/gamescope-convar-env-override.patch \
    && git apply /build/gamescope-gbm-scanout.patch \
    && meson setup build --buildtype=release -Denable_openvr_support=false \
    && grep -q -- '-DHAVE_GBM=1' build/compile_commands.json \
    && ninja -C build

FROM ${STEAM_RUNTIME_IMAGE}

ARG VERSION=0.1.0-dev
LABEL org.opencontainers.image.title="Quasar Steam application" \
      org.quasar.image.contract="1" \
      org.quasar.image.family="fedora" \
      org.quasar.image.base.version="${VERSION}" \
      org.quasar.image.acceleration="required" \
      org.quasar.image.graphics-apis="vulkan,egl,opengl" \
      org.quasar.image.entrypoint="/usr/local/bin/quasar-entrypoint"

# The gamescope RPM stays here rather than moving to quasar-steam-runtime: it is
# BPM-only weight and the runtime layer is shared with images that carry no
# gamescope. The patched binary below overwrites /usr/bin/gamescope, but the RPM
# is what drags in gamescope's shared-library dependencies -- without it the
# patched binary has 8 unresolved sonames (libSDL2, libseat, libinput, libavif,
# libXRes, libXmu, libeis, libluajit). Verified with ldd inside the image.
#
# seatd and drm_info serve direct display only (quasar#457): seatd is the seat
# daemon gamescope's DRM backend reaches through libseat (Fedora's libseat has no
# builtin backend), started by 25-steam-direct-seatd.sh; drm_info reports the
# kernel's mode list, from which the launcher picks the panel's native size at
# its highest refresh. Both are inert in a nested session.
#
# PipeWire, WirePlumber, the PulseAudio shim, the ALSA plugin and the pw-* tools
# are direct display's sound (quasar#457): a console session plays through the
# host's card, and /usr/local/libexec/quasar-steam/direct-session starts the
# daemons inside Steam's session bus. Nothing else starts them (no systemd user
# manager, no autostart), so a nested session is unchanged: no daemon runs and
# the agent-injected PULSE_SERVER still wins. ALSA's default stays on Pulse in
# both modes (/etc/asound.conf from quasar-app); in direct mode Pulse IS the shim.
RUN dnf --setopt=install_weak_deps=False -y install \
      gamescope seatd drm_info \
      pipewire wireplumber pipewire-pulseaudio pipewire-alsa pipewire-utils \
    && dnf clean all \
    && rm -rf /var/cache/dnf

COPY --from=gamescope-builder /build/gamescope/build/src/gamescope /usr/bin/gamescope
COPY images/quasar-steam/quasar-steam /usr/local/bin/quasar-steam
COPY images/quasar-steam/steam-wrapper /usr/local/bin/quasar-steam-client
COPY images/quasar-steam/direct-session /usr/local/libexec/quasar-steam/direct-session
COPY images/quasar-steam/overlay/etc/quasar/init.d/24-steam-direct-device-groups.sh \
     images/quasar-steam/overlay/etc/quasar/init.d/25-steam-direct-seatd.sh \
     /etc/quasar/init.d/
RUN chmod 0755 /usr/local/bin/quasar-steam /usr/local/bin/quasar-steam-client \
      /usr/local/libexec/quasar-steam/direct-session \
      /etc/quasar/init.d/24-steam-direct-device-groups.sh /etc/quasar/init.d/25-steam-direct-seatd.sh

# No baked GAMESCOPE_WIDTH/HEIGHT/REFRESH: a baked value is non-empty, so it
# would shadow the session mode Quasar injects as QUASAR_STREAM_* and pin every
# session to it (quasar#384 -- a 1440p120 session rendered 1080p60 and got
# upscaled). quasar-steam falls back to 1920x1080x60 internally when neither is
# set, so a standalone `docker run` is unchanged.
ENV QUASAR_STEAM_GAMESCOPE=1

CMD ["/usr/local/bin/quasar-steam"]
