# Quasar application base images

`quasar-base` is the shared Fedora 43 runtime for all Quasar application images. It supplies a digest-pinned Fedora base, certificates, timezone/locale support, process and diagnostic tools, a configurable unprivileged user, signal reaping, ordered root init hooks, and managed home/cache/runtime conventions. It intentionally excludes graphics drivers and build toolchains.

```sh
./scripts/build.sh
./scripts/verify.sh
```

## Image hierarchy

`quasar-app` builds on `quasar-base` and adds the shared Vulkan/EGL/OpenGL, Mesa, GLVND, GBM, Wayland, audio, NVIDIA-runtime initialization, and GPU-probe runtime. `quasar-diagnostics`, `quasar-test-vulkan`, and `quasar-test-egl` build on `quasar-app`.

```sh
./scripts/build.sh all
```

`quasar-diagnostics` is the browser layer; a generic browser base and a game layer are deliberately deferred until a second browser application or a real game workload needs them.

## Published images

Use manual workflow dispatch on `develop` to publish each image to `ghcr.io/salty2011/<image>:develop` and an immutable `sha-<commit>` tag. Pushes to `main` publish `:latest` and the same immutable SHA tag automatically. Pull requests and ordinary `develop` pushes only build; they never publish or start an accelerated image.

Accelerated launches provide `QUASAR_GPU_VULKAN_DEVICE_UUID`; `quasar-app` fails closed unless Vulkan selects that exact hardware UUID. PCI-BDF validation is added when Quasar's companion GPU-assignment transport exposes the mapping.
