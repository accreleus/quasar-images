ARG BASE_IMAGE=quasar-base:dev
FROM ${BASE_IMAGE}

ARG VERSION=0.1.0-dev
LABEL org.opencontainers.image.title="Quasar accelerated application runtime" \
      org.quasar.image.contract="1" \
      org.quasar.image.family="fedora" \
      org.quasar.image.base.version="${VERSION}" \
      org.quasar.image.acceleration="required" \
      org.quasar.image.graphics-apis="vulkan,egl,opengl" \
      org.quasar.image.entrypoint="/usr/local/bin/quasar-entrypoint"

RUN dnf --setopt=install_weak_deps=False -y install \
      alsa-plugins-pulseaudio alsa-lib \
      egl-wayland libglvnd-egl libglvnd-gles libglvnd-glx \
      libwayland-client libwayland-cursor libwayland-egl libxkbcommon \
      mesa-dri-drivers mesa-libEGL mesa-libGL mesa-libGLES mesa-libgbm \
      mesa-vulkan-drivers pipewire-libs pulseaudio-libs \
      vulkan-loader vulkan-tools \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Route ALSA-only clients to the node-agent-injected PulseAudio sink.
COPY overlay/etc/asound.conf /etc/asound.conf
RUN chmod 0644 /etc/asound.conf

COPY overlay/usr/local/bin/quasar-gpu-init /usr/local/bin/quasar-gpu-init
COPY overlay/usr/local/bin/quasar-gpu-probe /usr/local/bin/quasar-gpu-probe
RUN chmod 0755 /usr/local/bin/quasar-gpu-init /usr/local/bin/quasar-gpu-probe
