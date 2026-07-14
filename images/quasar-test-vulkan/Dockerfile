ARG APP_IMAGE=quasar-app:dev
FROM ${APP_IMAGE}

ARG VERSION=0.1.0-dev
LABEL org.opencontainers.image.title="Quasar native Vulkan reference workload" \
      org.quasar.image.contract="1" \
      org.quasar.image.family="fedora" \
      org.quasar.image.base.version="${VERSION}" \
      org.quasar.image.acceleration="required" \
      org.quasar.image.graphics-apis="vulkan,egl,opengl" \
      org.quasar.image.entrypoint="/usr/local/bin/quasar-entrypoint"

COPY images/quasar-test-vulkan/run-vulkan /usr/local/bin/quasar-test-vulkan
RUN chmod 0755 /usr/local/bin/quasar-test-vulkan
CMD ["/usr/local/bin/quasar-test-vulkan"]
