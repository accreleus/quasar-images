ARG APP_IMAGE=quasar-app:dev

# Steam's pressure-vessel sandbox rejects a non-setuid bwrap carrying
# capabilities. This follows GOW's narrowly scoped Bubblewrap workaround.
FROM ${APP_IMAGE} AS bwrap-builder

# PINNED, like every other third-party source this repo builds. It was an
# unpinned clone of the default branch, so the binary that ends up in every
# Steam and KDE image was "whatever bubblewrap's main branch was on build day" --
# unreproducible, and a silent way for an upstream change to reach production
# without anyone bumping anything. It also made the layer's content depend on the
# date rather than on the Dockerfile, so two boxes with identical inputs could
# ship different bwrap binaries. Bumping this is the deliberate act.
ARG BWRAP_REF=v0.11.2

RUN dnf --setopt=install_weak_deps=False -y install \
      ca-certificates dpkg-dev gcc git meson ninja-build patch \
    && dnf clean all \
    && rm -rf /var/cache/dnf

WORKDIR /build
COPY images/quasar-steam-runtime/ignore-capabilities.patch /build/ignore-capabilities.patch
RUN git clone --branch "${BWRAP_REF}" --depth 1 https://github.com/containers/bubblewrap.git \
    && cd bubblewrap \
    && ./ci/builddeps.sh \
    && patch -p1 < /build/ignore-capabilities.patch \
    && meson setup build --buildtype=release \
    && meson compile -C build

FROM ${APP_IMAGE}

ARG VERSION=0.1.0-dev
LABEL org.opencontainers.image.title="Quasar Steam runtime" \
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
      dbus-daemon file ibus lsb-release pciutils steam \
      NetworkManager \
      mesa-libGLU mesa-libGLU.i686 \
      libglvnd-egl.i686 libglvnd-gles.i686 libglvnd-glx.i686 \
      mesa-dri-drivers.i686 mesa-libEGL.i686 mesa-libGL.i686 mesa-libgbm.i686 \
      mesa-vulkan-drivers.i686 vulkan-loader.i686 \
    && dnf clean all \
    && rm -rf /var/cache/dnf

COPY --from=bwrap-builder /build/bubblewrap/build/bwrap /usr/bin/bwrap
RUN chmod 0755 /usr/bin/bwrap

# Steam Big Picture blocks on "Waiting for network" without a D-Bus system bus +
# NetworkManager to build its libnm client against (quasar-images#4). The hook
# runs as root from quasar-entrypoint's init.d chain; the conf keeps NM a
# read-only observer of docker's networking. See the files for the full trace.
COPY images/quasar-steam-runtime/overlay/etc/NetworkManager/conf.d/00-quasar.conf /etc/NetworkManager/conf.d/00-quasar.conf
COPY images/quasar-steam-runtime/overlay/etc/quasar/init.d/20-steam-system-services.sh /etc/quasar/init.d/20-steam-system-services.sh
RUN chmod 0644 /etc/NetworkManager/conf.d/00-quasar.conf \
    && chmod 0755 /etc/quasar/init.d/20-steam-system-services.sh
