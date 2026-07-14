ARG GRAPHICS_IMAGE=quasar/graphics-fedora:dev
FROM ${GRAPHICS_IMAGE}

ARG VERSION=0.1.0-dev

LABEL org.opencontainers.image.title="Quasar Fedora game foundation" \
      org.quasar.image.contract="1" \
      org.quasar.image.family="fedora" \
      org.quasar.image.base.version="${VERSION}" \
      org.quasar.image.acceleration="required" \
      org.quasar.image.graphics-apis="vulkan,egl,opengl" \
      org.quasar.image.entrypoint="/usr/local/bin/quasar-entrypoint"

RUN dnf --setopt=install_weak_deps=False -y install \
      fontconfig liberation-fonts \
      libglvnd-egl.i686 libglvnd-glx.i686 libglvnd-gles.i686 \
      mesa-dri-drivers.i686 mesa-libEGL.i686 mesa-libGL.i686 mesa-libgbm.i686 \
      mesa-vulkan-drivers.i686 vulkan-loader.i686 \
    && dnf clean all \
    && rm -rf /var/cache/dnf
