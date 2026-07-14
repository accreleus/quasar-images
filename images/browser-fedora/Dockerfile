ARG GRAPHICS_IMAGE=quasar/graphics-fedora:dev
FROM ${GRAPHICS_IMAGE}

ARG VERSION=0.1.0-dev

LABEL org.opencontainers.image.title="Quasar Fedora browser base" \
      org.quasar.image.contract="1" \
      org.quasar.image.family="fedora" \
      org.quasar.image.base.version="${VERSION}" \
      org.quasar.image.acceleration="required" \
      org.quasar.image.graphics-apis="vulkan,egl,opengl" \
      org.quasar.image.entrypoint="/usr/local/bin/quasar-entrypoint"

RUN dnf --setopt=install_weak_deps=False -y install \
      chromium dbus-libs fontconfig google-noto-sans-fonts \
      xdg-dbus-proxy xdg-desktop-portal \
    && dnf clean all \
    && rm -rf /var/cache/dnf

COPY images/browser-fedora/quasar-chromium /usr/local/bin/quasar-chromium
RUN chmod 0755 /usr/local/bin/quasar-chromium

