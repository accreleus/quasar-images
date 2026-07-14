# Quasar application base images

`quasar-base` is the shared Fedora 43 runtime for all Quasar application images. It supplies a digest-pinned Fedora base, certificates, timezone/locale support, process and diagnostic tools, a configurable unprivileged user, signal reaping, ordered root init hooks, and managed home/cache/runtime conventions. It intentionally excludes graphics drivers and build toolchains.

```sh
./scripts/build.sh
./scripts/verify.sh
```

## Image hierarchy

`quasar-app` builds on `quasar-base` and adds the shared Vulkan/EGL/OpenGL, Mesa, GLVND, GBM, Wayland, audio, NVIDIA-runtime initialization, and GPU-probe runtime. `quasar-diagnostics`, `quasar-test-vulkan`, `quasar-test-egl`, and `quasar-steam` build on `quasar-app`.

```sh
./scripts/build.sh all
```

`quasar-diagnostics` is the browser layer. `quasar-steam` adds Steam, RPM Fusion, 32-bit graphics libraries, Gamescope, and a GOW-derived Bubblewrap compatibility workaround. It launches Steam in Gamepad UI through nested Gamescope by default. It deliberately excludes Decky, host input mounts, and service daemons because Quasar owns those policies.

## Published images

Use manual workflow dispatch on `develop` to build and publish each image to `ghcr.io/salty2011/<image>:develop` and an immutable `sha-<commit>` tag. Pushes to `main` build and publish `:latest` and the same immutable SHA tag automatically. Pull requests build only; ordinary `develop` pushes do not trigger a workflow.

Accelerated launches provide `QUASAR_GPU_VULKAN_DEVICE_UUID`; `quasar-app` fails closed unless Vulkan selects that exact hardware UUID. PCI-BDF validation is added when Quasar's companion GPU-assignment transport exposes the mapping.
