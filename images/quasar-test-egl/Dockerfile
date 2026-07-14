ARG APP_IMAGE=quasar-app:dev
FROM ${APP_IMAGE}

ARG VERSION=0.1.0-dev
RUN dnf --setopt=install_weak_deps=False -y install mesa-demos \
    && dnf clean all \
    && rm -rf /var/cache/dnf

LABEL org.opencontainers.image.title="Quasar native EGL reference workload" \
      org.quasar.image.contract="1" \
      org.quasar.image.family="fedora" \
      org.quasar.image.base.version="${VERSION}" \
      org.quasar.image.acceleration="required" \
      org.quasar.image.graphics-apis="vulkan,egl,opengl" \
      org.quasar.image.entrypoint="/usr/local/bin/quasar-entrypoint"

COPY images/quasar-test-egl/run-egl /usr/local/bin/quasar-test-egl
RUN chmod 0755 /usr/local/bin/quasar-test-egl
CMD ["/usr/local/bin/quasar-test-egl"]
