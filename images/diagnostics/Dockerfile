ARG BROWSER_IMAGE=quasar/browser-fedora:dev
FROM ${BROWSER_IMAGE}

ARG VERSION=0.1.0-dev
LABEL org.opencontainers.image.title="Quasar diagnostics image" \
      org.quasar.image.contract="1" \
      org.quasar.image.family="fedora" \
      org.quasar.image.base.version="${VERSION}" \
      org.quasar.image.acceleration="required" \
      org.quasar.image.graphics-apis="vulkan,egl,opengl" \
      org.quasar.image.entrypoint="/usr/local/bin/quasar-entrypoint"

COPY images/diagnostics/start-diagnostics /usr/local/bin/start-diagnostics
RUN chmod 0755 /usr/local/bin/start-diagnostics
CMD ["/usr/local/bin/start-diagnostics"]

