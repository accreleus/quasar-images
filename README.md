# Quasar application base images

`quasar-base` is the shared Fedora 43 runtime for all Quasar application images. It supplies a digest-pinned Fedora base, certificates, timezone/locale support, process and diagnostic tools, a configurable unprivileged user, signal reaping, ordered root init hooks, and managed home/cache/runtime conventions. It intentionally excludes graphics drivers and build toolchains.

```sh
./scripts/build.sh
./scripts/verify.sh
```

## Image hierarchy

`quasar-app` builds on `quasar-base` and adds the shared Vulkan/EGL/OpenGL, Mesa, GLVND, GBM, Wayland, audio, NVIDIA-runtime initialization, and GPU-probe runtime. `quasar-diagnostics`, `quasar-test-vulkan`, `quasar-test-egl`, and `quasar-steam-runtime` build on `quasar-app`. **`quasar-test-vulkan` and `quasar-test-egl` are local-only GPU probes** — buildable via `./scripts/build.sh`, deliberately NOT published, because nothing consumes them from a registry.

```sh
./scripts/build.sh all
```

`quasar-diagnostics` is the browser layer. `quasar-steam-runtime` builds on `quasar-app` and holds the mode-neutral Steam stack: RPM Fusion repos, `steam`, 32-bit graphics userspace, and a patched non-setuid Bubblewrap build (pressure-vessel rejects a bwrap binary carrying capabilities in any UI mode), plus the system-bus/NetworkManager init hook the Steam client depends on. `quasar-steam` and `quasar-kde` both build on `quasar-steam-runtime`.

`quasar-steam` adds the patched Gamescope build and the Big Picture console launcher. It launches Steam in a game-console experience through nested Gamescope by default (legacy Big Picture, the games-on-whales-validated game-foreground path; a modern gamepadui Deck-session mode is opt-in). See `images/quasar-steam/README.md` for the focus mechanism and the host `--shm-size`, 32-bit driver, audio, and PUID/PGID requirements. It deliberately excludes Decky, host input mounts, and service daemons because Quasar owns those policies.

`quasar-kde` adds a KDE Plasma 6 Wayland desktop session, carrying zero Gamescope/Big-Picture weight. It ships the Steam **desktop** client (the same RPM as `quasar-steam`, launched as plain `steam` from the Kickoff menu instead of `steam -bigpicture` under Gamescope), user-level Flatpak with Plasma Discover, and Quasar branding (Kickoff icon, baked Plasma defaults). No autostart of Steam or Flatpak apps — the session boots to an empty desktop.

Host requirements for `quasar-kde`: the parent Wayland compositor socket must be handed off (`WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR`), same as other Quasar desktop sessions. A persistent `/home/quasar` volume is required (image carries `org.quasar.image.persist=/home/quasar`; one session per home volume) and the image carries `org.quasar.image.session=desktop`. Same `--shm-size` requirement as `quasar-steam`. `no_new_privileges` must stay `false` (Steam's startup re-escalation, same reason as `quasar-steam`). User-level Flatpak (Discover, `flatpak install`/`flatpak run`) needs an unprivileged user namespace — the agent must run the container with a seccomp profile permitting `clone(CLONE_NEWUSER)` — **and** the container's default `/proc` masking disabled (`docker run --security-opt systempaths=unconfined`): without it, `flatpak install` succeeds but `flatpak run`'s bwrap sandbox fails to mount `/proc` (live-verified 2026-08-13). Mounting `/run/quasar/share` for agent-provided game-menu entries is optional.

## Published images

Branching model: **`stable` is the default and published branch; `develop` is the persistent integration branch.** Use manual workflow dispatch on `develop` to build and publish each image to `ghcr.io/accretion-io/<image>:develop` and an immutable `sha-<commit>` tag. Pushes to `stable` build and publish `:latest` and the same immutable SHA tag automatically. Pull requests build only; ordinary `develop` pushes do not trigger a workflow.

`quasar-manifest.json` at the repository root is the **app-image catalog manifest** the Quasar control plane consumes (`GET /v1/admin/images`, `POST /v1/admin/images/sync`). It is a contract surface — Quasar refuses a `manifest_version` it does not understand. See `MANIFEST.md` before editing it.

When a launch provides `QUASAR_GPU_VULKAN_DEVICE_UUID`, `quasar-app` fails closed unless Vulkan selects that exact hardware UUID. Without it (the Quasar agent does not ship GPU-UUID assignment yet — quasar#273) the probe still rejects software renderers but accepts whichever hardware device the runtime injected. PCI-BDF validation is added when Quasar's companion GPU-assignment transport exposes the mapping.
