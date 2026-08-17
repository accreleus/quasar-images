# quasar-benchapp — the instrumented streaming probe workload.
#
# Unlike quasar-unigine (an X11/GLX benchmark that needs a gamescope+Xwayland
# bridge), quasar-benchapp is a NATIVE Wayland client: it binds xdg_shell on the
# socket the node-agent hands the session and goes fullscreen borderless. There
# is deliberately no nested compositor in this image — inserting gamescope would
# add a second compositor's pacing and scaling between the probe and the encoder,
# which is exactly the signal this image exists to measure.
#
# The payload is built from the separate `quasar-benchgame` repo. That repo is
# not published, so its build is not reproducible from this context alone; the
# binary is lifted from a locally built image instead:
#
#   (in quasar-benchgame)  docker build -t quasar-benchapp:src .
#   (here)                 QUASAR_IMAGE_TAG=dev ./scripts/build.sh quasar-benchapp
#
# BENCHAPP_SRC_IMAGE names that stage image so a future published source repo can
# be swapped in by overriding one build arg.

ARG APP_IMAGE=quasar-app:dev
ARG BENCHAPP_SRC_IMAGE=quasar-benchapp:src

FROM ${BENCHAPP_SRC_IMAGE} AS benchapp-src

FROM ${APP_IMAGE}

ARG VERSION=0.1.0-dev
ARG BENCHAPP_GIT_SHA=unknown

LABEL org.opencontainers.image.title="Quasar benchapp streaming probe" \
      org.opencontainers.image.description="Deterministic native-Wayland Vulkan probe that stamps every frame with a machine-readable luma marker and logs per-frame timing against CLOCK_REALTIME, for end-to-end cloud-gaming pipeline measurement." \
      org.quasar.image.contract="1" \
      org.quasar.image.family="fedora" \
      org.quasar.image.base.version="${VERSION}" \
      org.quasar.image.acceleration="required" \
      org.quasar.image.graphics-apis="vulkan" \
      org.quasar.image.persist="/home/quasar" \
      org.quasar.image.entrypoint="/usr/local/bin/quasar-entrypoint" \
      org.quasar.benchapp.git-sha="${BENCHAPP_GIT_SHA}"

# quasar-app already carries vulkan-loader, mesa-vulkan-drivers, libwayland-client
# and libxkbcommon — the probe's entire runtime closure except libwayland-cursor,
# which winit dlopens for pointer themes. `socat` is what lets an operator (or the
# harness) drive the probe's control socket from inside the container.
RUN dnf --setopt=install_weak_deps=False -y install \
      libwayland-cursor \
      socat \
    && dnf clean all \
    && rm -rf /var/cache/dnf

COPY --from=benchapp-src /usr/local/bin/benchapp /usr/local/bin/benchapp
COPY --from=benchapp-src /usr/local/bin/run.sh   /usr/local/bin/benchapp-run.sh
COPY --from=benchapp-src /app/scenes             /opt/benchapp/scenes
COPY images/quasar-benchapp/quasar-benchapp /usr/local/bin/quasar-benchapp
RUN chmod 0755 /usr/local/bin/benchapp /usr/local/bin/benchapp-run.sh \
                /usr/local/bin/quasar-benchapp \
    && chmod -R a+rX /opt/benchapp

# Defaults are set in the launcher, not here, so that `${VAR:-default}` resolution
# happens once and an empty-string override behaves the same as an unset one. The
# two exceptions below are inert-but-useful process environment.
#
# BENCHAPP_RENDER is deliberately NOT baked: unset means "render at the surface
# size the compositor configures", which is what makes the probe follow Quasar's
# live resolution changes (quasar#384 / the session-display PATCH path). A baked
# value would pin the internal render size for every session and silently defeat
# the resolution-ladder tests this image is meant to measure.
ENV WGPU_BACKEND=vulkan \
    BENCHAPP_SCENES_DIR=/opt/benchapp/scenes

CMD ["/usr/local/bin/quasar-benchapp"]
