ARG BASE_IMAGE=quasar/base-fedora:dev
FROM ${BASE_IMAGE}

ARG VERSION=0.1.0-dev

LABEL org.opencontainers.image.title="Quasar Fedora graphics base" \
      org.quasar.image.contract="1" \
      org.quasar.image.family="fedora" \
      org.quasar.image.base.version="${VERSION}" \
      org.quasar.image.acceleration="required" \
      org.quasar.image.graphics-apis="vulkan,egl,opengl" \
      org.quasar.image.entrypoint="/usr/local/bin/quasar-entrypoint"

RUN dnf --setopt=install_weak_deps=False -y install \
      libglvnd-egl libglvnd-glx libglvnd-gles \
      pulseaudio-libs mesa-dri-drivers mesa-libEGL mesa-libGL mesa-libgbm mesa-libGLES \
      mesa-vulkan-drivers pipewire-libs \
      vulkan-loader vulkan-tools \
      libwayland-client libwayland-cursor libwayland-egl libxkbcommon \
      egl-wayland \
    && dnf clean all \
    && rm -rf /var/cache/dnf

COPY overlay/usr/local/bin/quasar-gpu-init /usr/local/bin/quasar-gpu-init
COPY overlay/usr/local/bin/quasar-gpu-probe /usr/local/bin/quasar-gpu-probe
COPY overlay/etc/quasar/gpu.d/ /etc/quasar/gpu.d/

RUN chmod 0755 /usr/local/bin/quasar-gpu-init /usr/local/bin/quasar-gpu-probe
