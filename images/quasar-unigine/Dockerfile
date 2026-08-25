ARG APP_IMAGE=quasar-app:dev
FROM ${APP_IMAGE}

ARG VERSION=0.1.0-dev

# Both benchmarks are optional so the image can be built small (Heaven only,
# ~340 MB extracted) on a disk-constrained host. Superposition is ~1.7 GB
# extracted and defaults ON; pass --build-arg WITH_SUPERPOSITION=0 to skip it.
ARG WITH_HEAVEN=1
ARG WITH_SUPERPOSITION=1

# Official UNIGINE downloads. Both are Makeself 2.4.0 self-extracting archives;
# `--noexec --target DIR` extracts without running the embedded installer (which
# only writes .desktop files and icons into $HOME -- useless in a container).
# The sha256 sums are pinned so a silently repointed asset fails the build
# rather than shipping a different benchmark under the same tag.
ARG HEAVEN_URL=https://assets.unigine.com/d/Unigine_Heaven-4.0.run
ARG HEAVEN_SHA256=52db2e5dedd5621d7c2bfa936b482c0a7cc69b30616278ef199513d494d8e397
ARG SUPERPOSITION_URL=https://assets.unigine.com/d/Unigine_Superposition-1.1.run
ARG SUPERPOSITION_SHA256=7494e1c73bf59ef2161513d5d5cb9d9bffbd8479929d4976ac53b6955de580f8

LABEL org.opencontainers.image.title="Quasar UNIGINE benchmark workload" \
      org.opencontainers.image.description="UNIGINE Heaven 4.0 and Superposition 1.1 running as a self-driving, looping GPU benchmark for Quasar streaming tests." \
      org.quasar.image.contract="1" \
      org.quasar.image.family="fedora" \
      org.quasar.image.base.version="${VERSION}" \
      org.quasar.image.acceleration="required" \
      org.quasar.image.graphics-apis="opengl,egl,vulkan" \
      org.quasar.image.persist="/home/quasar" \
      org.quasar.image.entrypoint="/usr/local/bin/quasar-entrypoint"

# gamescope is what gives this image an X server: the UNIGINE benchmarks are
# X11/GLX clients and Quasar hands the session a *Wayland* socket, so something
# has to bridge. Stock Fedora gamescope is used deliberately -- quasar-steam
# carries a patched build only for Big Picture's Passthrough touch/pointer
# routing, and these benchmarks take no input at all, so the patch is dead
# weight here. Installing the RPM also drags in Xwayland and gamescope's own
# shared-library closure, which is the actual reason it is the lightest route
# to a GLX-capable display (a hand-rolled rootless Xwayland would still need
# a window manager to size and map the benchmark window).
#
# libXinerama/libXrandr/libXrender are the three sonames heaven_x64 needs that
# quasar-app does not already carry (verified with ldd inside quasar-app:dev).
# mesa-libGLU is not needed; the benchmarks bundle everything else in bin/x64.
RUN dnf --setopt=install_weak_deps=False -y install \
      gamescope \
      libXinerama libXrandr libXrender libXcursor libXi \
      openal-soft \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# BuildKit cache mount for the installers: a rebuild of the layers below must
# not re-pull 1.9 GB. The .run files never land in an image layer.
#
# The extracted trees arrive 0770/root, so `chmod -R a+rX` is what makes the
# binaries and data readable/executable by the unprivileged session uid.
# `data/` additionally gets write permission: the UNIGINE engine rewrites its
# engine_config on exit. That write lands in the container's ephemeral upper
# layer, NOT the managed home, so every session starts from the pristine baked
# config -- which is exactly the determinism a benchmark wants.
# The x86 halves, PDFs and desktop-integration leftovers are dropped: ~90 MB of
# weight this image can never use.
RUN --mount=type=cache,target=/var/cache/unigine,sharing=locked \
    set -eux; \
    mkdir -p /opt/unigine; \
    if [ "${WITH_HEAVEN}" = "1" ]; then \
      f=/var/cache/unigine/Unigine_Heaven-4.0.run; \
      [ -f "$f" ] || curl -fsSL -o "$f" "${HEAVEN_URL}"; \
      echo "${HEAVEN_SHA256}  $f" | sha256sum -c -; \
      sh "$f" --noexec --nochown --noprogress --nox11 --quiet --target /opt/unigine/heaven; \
    fi; \
    if [ "${WITH_SUPERPOSITION}" = "1" ]; then \
      f=/var/cache/unigine/Unigine_Superposition-1.1.run; \
      [ -f "$f" ] || curl -fsSL -o "$f" "${SUPERPOSITION_URL}"; \
      echo "${SUPERPOSITION_SHA256}  $f" | sha256sum -c -; \
      sh "$f" --noexec --nochown --noprogress --nox11 --quiet --target /opt/unigine/superposition; \
    fi; \
    rm -rf /opt/unigine/*/documentation /opt/unigine/*/docs /opt/unigine/*/icons \
           /opt/unigine/*/bin/x86 /opt/unigine/*/bin/*_x86 /opt/unigine/*/bin/*_x86.so* \
           /opt/unigine/*/postinstall.sh /opt/unigine/*/uninstall.sh; \
    chmod -R a+rX /opt/unigine; \
    chmod -R a+rwX /opt/unigine/*/data; \
    du -sh /opt/unigine/*

COPY images/quasar-unigine/quasar-unigine /usr/local/bin/quasar-unigine
RUN chmod 0755 /usr/local/bin/quasar-unigine

# No baked UNIGINE_WIDTH/HEIGHT: a baked value is non-empty and would shadow the
# session mode Quasar injects as QUASAR_STREAM_* (quasar#384). The launcher
# falls back to 1920x1080 internally when neither is set.
ENV UNIGINE_BENCH=heaven \
    UNIGINE_QUALITY=high \
    UNIGINE_FULLSCREEN=1 \
    UNIGINE_LOOP=1 \
    UNIGINE_SOUND=null

CMD ["/usr/local/bin/quasar-unigine"]
