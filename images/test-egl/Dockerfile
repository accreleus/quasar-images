ARG GRAPHICS_IMAGE=quasar/graphics-fedora:dev
FROM ${GRAPHICS_IMAGE}
RUN dnf --setopt=install_weak_deps=False -y install mesa-demos && dnf clean all && rm -rf /var/cache/dnf
LABEL org.opencontainers.image.title="Quasar EGL reference workload scaffold"
CMD ["eglinfo"]

