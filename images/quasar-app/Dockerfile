ARG BASE_IMAGE=quasar-base:dev

# --- quasar-display-bridge: the display-mode bridge (quasar #445, quasar-images#447) ------
# A rootful Xwayland ignores the compositor's wl_output modes and lists its own fixed 60 Hz
# table, so an X11 desktop's display settings could never show the monitor's real modes nor
# send a choice anywhere. This ~30 KB C program mirrors the Quasar compositor's
# wlr-output-management modes into RandR and forwards the user's pick back; see
# images/quasar-app/display-bridge/quasar-display-bridge.c for the whole mechanism. It is not
# XFCE-specific -- any X11 desktop nested on a rootful Xwayland can start it the same way, so
# it lives here in the shared spine rather than being re-implemented per desktop image. Built
# in a throwaway stage so the final image carries the binary and none of the toolchain or
# -devel packages.
FROM ${BASE_IMAGE} AS display-bridge-builder
RUN dnf --setopt=install_weak_deps=False --setopt=tsflags=nodocs -y install \
      gcc make pkgconf-pkg-config wayland-devel wlr-protocols-devel \
      libX11-devel libXrandr-devel \
    && dnf clean all
COPY images/quasar-app/display-bridge /src/display-bridge
RUN make -C /src/display-bridge

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
      libX11 libXrandr \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Route ALSA-only clients to the node-agent-injected PulseAudio sink.
COPY overlay/etc/asound.conf /etc/asound.conf
RUN chmod 0644 /etc/asound.conf

# Additive search path for the 32-bit NVIDIA driver volume the node-agent
# mounts at /opt/quasar/nvidia-lib32 on NVIDIA hosts (issue #375) — never bakes
# driver libs into the image, only where ldconfig should look for them.
COPY overlay/etc/ld.so.conf.d/90-quasar-nvidia-volume.conf /etc/ld.so.conf.d/90-quasar-nvidia-volume.conf
RUN chmod 0644 /etc/ld.so.conf.d/90-quasar-nvidia-volume.conf

COPY overlay/usr/local/bin/quasar-gpu-init /usr/local/bin/quasar-gpu-init
COPY overlay/usr/local/bin/quasar-gpu-probe /usr/local/bin/quasar-gpu-probe
RUN chmod 0755 /usr/local/bin/quasar-gpu-init /usr/local/bin/quasar-gpu-probe

# quasar-xfce-modes is a compatibility symlink for anything still invoking the
# bridge under its pre-move (quasar-images#447) XFCE-specific name.
COPY --from=display-bridge-builder /src/display-bridge/quasar-display-bridge /usr/local/bin/quasar-display-bridge
RUN chmod 0755 /usr/local/bin/quasar-display-bridge \
    && ln -s quasar-display-bridge /usr/local/bin/quasar-xfce-modes
