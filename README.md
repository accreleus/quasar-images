# Quasar application base images

`quasar-base` is the shared Fedora 43 runtime for all Quasar application images. It supplies a digest-pinned Fedora base, certificates, timezone/locale support, process and diagnostic tools, a configurable unprivileged user, signal reaping, ordered root init hooks, and managed home/cache/runtime conventions. It intentionally excludes graphics drivers and build toolchains.

```sh
./scripts/build.sh
./scripts/verify.sh
```

## Image hierarchy

`quasar-app` builds on `quasar-base` and adds the shared Vulkan/EGL/OpenGL, Mesa, GLVND, GBM, Wayland, audio, NVIDIA-runtime initialization, and GPU-probe runtime. `quasar-diagnostics`, `quasar-test-vulkan`, `quasar-test-egl`, and `quasar-steam` build on `quasar-app`. **`quasar-test-vulkan` and `quasar-test-egl` are local-only GPU probes** — buildable via `./scripts/build.sh`, deliberately NOT published, because nothing consumes them from a registry.

```sh
./scripts/build.sh all
```

`quasar-diagnostics` is the browser layer. `quasar-steam` adds Steam, RPM Fusion, 32-bit graphics libraries, Gamescope, and a GOW-derived Bubblewrap compatibility workaround. It launches Steam in a game-console experience through nested Gamescope by default (legacy Big Picture, the games-on-whales-validated game-foreground path; a modern gamepadui Deck-session mode is opt-in). See `images/quasar-steam/README.md` for the focus mechanism and the host `--shm-size`, 32-bit driver, audio, and PUID/PGID requirements. It deliberately excludes Decky, host input mounts, and service daemons because Quasar owns those policies.

## Published images

Branching model: **`stable` is the default and published branch; `develop` is the persistent integration branch.** Use manual workflow dispatch on `develop` to build and publish each image to `ghcr.io/accretion-io/<image>:develop` and an immutable `sha-<commit>` tag. Pushes to `stable` build and publish `:latest` and the same immutable SHA tag automatically. Pull requests build only; ordinary `develop` pushes do not trigger a workflow.

`quasar-manifest.json` at the repository root is the **app-image catalog manifest** the Quasar control plane consumes (`GET /v1/admin/images`, `POST /v1/admin/images/sync`). It is a contract surface — Quasar refuses a `manifest_version` it does not understand. See `MANIFEST.md` before editing it.

When a launch provides `QUASAR_GPU_VULKAN_DEVICE_UUID`, `quasar-app` fails closed unless Vulkan selects that exact hardware UUID. Without it (the Quasar agent does not ship GPU-UUID assignment yet — quasar#273) the probe still rejects software renderers but accepts whichever hardware device the runtime injected. PCI-BDF validation is added when Quasar's companion GPU-assignment transport exposes the mapping.
