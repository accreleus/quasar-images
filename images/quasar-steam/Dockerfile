ARG APP_IMAGE=quasar-app:dev

# Steam's pressure-vessel sandbox rejects a non-setuid bwrap carrying
# capabilities. This follows GOW's narrowly scoped Bubblewrap workaround.
FROM ${APP_IMAGE} AS bwrap-builder

RUN dnf --setopt=install_weak_deps=False -y install \
      ca-certificates dpkg-dev gcc git meson ninja-build patch \
    && dnf clean all \
    && rm -rf /var/cache/dnf

WORKDIR /build
COPY images/quasar-steam/ignore-capabilities.patch /build/ignore-capabilities.patch
RUN git clone https://github.com/containers/bubblewrap.git \
    && cd bubblewrap \
    && ./ci/builddeps.sh \
    && patch -p1 < /build/ignore-capabilities.patch \
    && meson setup build --buildtype=release \
    && meson compile -C build

FROM ${APP_IMAGE}

ARG VERSION=0.1.0-dev
LABEL org.opencontainers.image.title="Quasar Steam application" \
      org.quasar.image.contract="1" \
      org.quasar.image.family="fedora" \
      org.quasar.image.base.version="${VERSION}" \
      org.quasar.image.acceleration="required" \
      org.quasar.image.graphics-apis="vulkan,egl,opengl" \
      org.quasar.image.entrypoint="/usr/local/bin/quasar-entrypoint"

RUN dnf --setopt=install_weak_deps=False -y install \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
    && dnf --setopt=install_weak_deps=False -y install \
      dbus-daemon file gamescope ibus lsb-release pciutils steam \
      mesa-libGLU mesa-libGLU.i686 \
      libglvnd-egl.i686 libglvnd-gles.i686 libglvnd-glx.i686 \
      mesa-dri-drivers.i686 mesa-libEGL.i686 mesa-libGL.i686 mesa-libgbm.i686 \
      mesa-vulkan-drivers.i686 vulkan-loader.i686 \
    && dnf clean all \
    && rm -rf /var/cache/dnf

COPY --from=bwrap-builder /build/bubblewrap/build/bwrap /usr/bin/bwrap
COPY images/quasar-steam/quasar-steam /usr/local/bin/quasar-steam
COPY images/quasar-steam/steam-wrapper /usr/local/bin/quasar-steam-client
RUN chmod 0755 /usr/local/bin/quasar-steam /usr/local/bin/quasar-steam-client /usr/bin/bwrap

ENV QUASAR_STEAM_GAMESCOPE=1 \
    GAMESCOPE_WIDTH=1920 \
    GAMESCOPE_HEIGHT=1080 \
    GAMESCOPE_REFRESH=60

CMD ["/usr/local/bin/quasar-steam"]
