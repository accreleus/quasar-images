ARG APP_IMAGE=quasar-app:dev
FROM ${APP_IMAGE}

ARG VERSION=0.1.0-dev
LABEL org.opencontainers.image.title="Quasar browser diagnostics" \
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

COPY images/quasar-diagnostics/quasar-diagnostics /usr/local/bin/quasar-diagnostics
RUN chmod 0755 /usr/local/bin/quasar-diagnostics
CMD ["/usr/local/bin/quasar-diagnostics"]
