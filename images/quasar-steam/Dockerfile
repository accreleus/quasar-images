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
# Builds from ${APP_IMAGE}, not the Steam runtime: the builder only needs the
# Fedora toolchain + `dnf builddep gamescope`, so keeping it on quasar-app
# leaves it independent of the runtime layer (and its build cache).
FROM ${APP_IMAGE} AS gamescope-builder

RUN dnf --setopt=install_weak_deps=False -y install \
      git meson ninja-build gcc gcc-c++ \
      xorg-x11-server-Xwayland-devel \
    && (dnf -y install dnf5-plugins || dnf -y install dnf-plugins-core) \
    && (dnf builddep -y gamescope || dnf builddep -y --enablerepo="*source*" gamescope) \
    && dnf clean all && rm -rf /var/cache/dnf

WORKDIR /build
COPY images/quasar-steam/gamescope-nested-pointer-warp.patch /build/
RUN git clone --branch 3.16.23 --depth 1 --recurse-submodules https://github.com/ValveSoftware/gamescope.git \
    && cd gamescope \
    && git apply /build/gamescope-nested-pointer-warp.patch \
    && meson setup build --buildtype=release -Denable_openvr_support=false \
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
RUN dnf --setopt=install_weak_deps=False -y install \
      gamescope \
    && dnf clean all \
    && rm -rf /var/cache/dnf

COPY --from=gamescope-builder /build/gamescope/build/src/gamescope /usr/bin/gamescope
COPY images/quasar-steam/quasar-steam /usr/local/bin/quasar-steam
COPY images/quasar-steam/steam-wrapper /usr/local/bin/quasar-steam-client
RUN chmod 0755 /usr/local/bin/quasar-steam /usr/local/bin/quasar-steam-client

# No baked GAMESCOPE_WIDTH/HEIGHT/REFRESH: a baked value is non-empty, so it
# would shadow the session mode Quasar injects as QUASAR_STREAM_* and pin every
# session to it (quasar#384 -- a 1440p120 session rendered 1080p60 and got
# upscaled). quasar-steam falls back to 1920x1080x60 internally when neither is
# set, so a standalone `docker run` is unchanged.
ENV QUASAR_STEAM_GAMESCOPE=1

CMD ["/usr/local/bin/quasar-steam"]
