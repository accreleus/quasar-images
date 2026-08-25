# Quasar application base images

`quasar-base` is the shared Fedora 43 runtime for all Quasar application images. It supplies a digest-pinned Fedora base, certificates, timezone/locale support, process and diagnostic tools, a configurable unprivileged user, signal reaping, ordered root init hooks, and managed home/cache/runtime conventions. It intentionally excludes graphics drivers and build toolchains.

```sh
./scripts/build.sh                    # every image
./scripts/build.sh quasar-kde         # one image and its ancestors
./scripts/build.sh verify quasar-kde  # its verify scripts
./scripts/build.sh check              # validate build-graph.json
```

**`build-graph.json` states the build DAG once** — order, build args, verify
wiring, what CI builds, what gets published — and both `scripts/build.sh` and
the GitHub Actions workflow read it through `scripts/graph.sh`. Adding an image
is a Dockerfile plus an entry there. **`AGENTS.md` is the operating guide**: the
DAG, adding an image, validating locally, the layer cache and its three hard
constraints, the pin policy, the KWin artefact, and what CI does per event.

## Image hierarchy

`quasar-app` builds on `quasar-base` and adds the shared Vulkan/EGL/OpenGL, Mesa, GLVND, GBM, Wayland, audio, NVIDIA-runtime initialization, and GPU-probe runtime. `quasar-diagnostics`, `quasar-test-vulkan`, `quasar-test-egl`, and `quasar-steam-runtime` build on `quasar-app`. **`quasar-test-vulkan` and `quasar-test-egl` are local-only GPU probes** — buildable via `./scripts/build.sh`, deliberately NOT published, because nothing consumes them from a registry.

```sh
./scripts/build.sh all
```

`quasar-diagnostics` is the browser layer. `quasar-steam-runtime` builds on `quasar-app` and holds the mode-neutral Steam stack: RPM Fusion repos, `steam`, 32-bit graphics userspace, and a patched non-setuid Bubblewrap build (pressure-vessel rejects a bwrap binary carrying capabilities in any UI mode), plus the system-bus/NetworkManager init hook the Steam client depends on. `quasar-steam`, `quasar-kde` and `quasar-xfce` all build on `quasar-steam-runtime`.

`quasar-steam` adds the patched Gamescope build and the Big Picture console launcher. It launches Steam in a game-console experience through nested Gamescope by default (legacy Big Picture, the games-on-whales-validated game-foreground path; a modern gamepadui Deck-session mode is opt-in). See `images/quasar-steam/README.md` for the focus mechanism and the host `--shm-size`, 32-bit driver, audio, and PUID/PGID requirements. It deliberately excludes Decky, host input mounts, and service daemons because Quasar owns those policies.

`quasar-kde` adds a KDE Plasma 6 Wayland desktop session, carrying zero Gamescope/Big-Picture weight. It ships the Steam **desktop** client (the same RPM as `quasar-steam`, launched as plain `steam` from the Kickoff menu instead of `steam -bigpicture` under Gamescope), user-level Flatpak with Plasma Discover, and Quasar branding (Kickoff icon, baked Plasma defaults). No autostart of Steam or Flatpak apps — the session boots to an empty desktop.

Host requirements for `quasar-kde`: the parent Wayland compositor socket must be handed off (`WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR`), same as other Quasar desktop sessions. A persistent `/home/quasar` volume is required (image carries `org.quasar.image.persist=/home/quasar`; one session per home volume) and the image carries `org.quasar.image.session=desktop`. Same `--shm-size` requirement as `quasar-steam`. `no_new_privileges` must stay `false` (Steam's startup re-escalation, same reason as `quasar-steam`). User-level Flatpak (Discover, `flatpak install`/`flatpak run`) needs an unprivileged user namespace — the agent must run the container with a seccomp profile permitting `clone(CLONE_NEWUSER)` — **and** the container's default `/proc` masking disabled (`docker run --security-opt systempaths=unconfined`): without it, `flatpak install` succeeds but `flatpak run`'s bwrap sandbox fails to mount `/proc` (live-verified 2026-08-13). Mounting `/run/quasar/share` for agent-provided game-menu entries is optional.

`quasar-xfce` adds an XFCE 4 X11 desktop session, running the rootful Xwayland nested under the Quasar compositor (the games-on-whales-validated pattern for an X11-only desktop environment). It ships the Steam **desktop** client (same RPM as `quasar-steam` and `quasar-kde`), user-level Flatpak with gnome-software as the store (+190MB measured over the bare XFCE session set — XFCE has no Discover-equivalent native store), a Quasar-branded Whisker-menu icon, and `firefox`. Host requirements are the same as `quasar-kde` above (persistent `/home/quasar`, `org.quasar.image.session=desktop`, `--shm-size`, `no_new_privileges=false`, and the user-namespace + `--security-opt systempaths=unconfined` pair for Flatpak), plus one XFCE-specific note: because the session is X11-only, the launcher unsets `WAYLAND_DISPLAY` for the whole session and applies `flatpak override --user --nosocket=wayland` so every Flatpak app stays inside the nested X session instead of reaching the parent compositor directly.

Note for anyone wiring a GStreamer sink directly against the parent compositor socket instead of going through a launcher: `waylandsink` needs `XDG_RUNTIME_DIR` plus a *relative* socket name and rejects an absolute `WAYLAND_DISPLAY` — the opposite of the absolute-path convention above. See `docs/specs/2026-08-15-quasar-gnome-blocked.md` §4 (found while investigating `quasar-gnome`, which does not exist as an image).

### `quasar-unigine` — the benchmark workload

`quasar-unigine` builds on `quasar-app` and carries **UNIGINE Heaven 4.0** and **UNIGINE Superposition 1.1** as an autonomous, deterministic GPU load for Quasar streaming tests. It is not a game tile; it exists so that encoder, ABR, and latency work has a repeatable workload that drives itself.

**Why these benchmarks and not a game.** The previous candidate (Redout, via Steam) stopped at a photosensitivity gate that needed a scripted keypress, and once past it the ship sat stationary on the grid. UNIGINE's benchmarks take **no input at all**: the `PHORONIX` token in `-extern_define` selects the automation branch of the system script, which runs the full scene sequence unattended, prints a score, and exits. The launcher then restarts it. That gives a genuinely moving flythrough with no harness-side input plumbing.

**Why gamescope is in this image.** The benchmarks are X11/GLX clients and Quasar hands a session a Wayland socket, so something has to bridge. Stock Fedora `gamescope` is used, not the patched build `quasar-steam` carries — that patch exists only for Big Picture's Passthrough pointer routing, and a benchmark that takes no input does not need it. Installing the RPM also drags in Xwayland and gamescope's library closure, which is what makes it the lightest working route; a hand-rolled rootless Xwayland would still need a window manager to size and map the benchmark window. The launcher uses the same ready-socket handshake as `quasar-steam` (gamescope runs with no client argument and reports its real `DISPLAY` through `-R`), and runs the benchmark as a **sibling** so each pass can be restarted without tearing the X server down.

**Configuration** (all env, all optional):

| var | default | meaning |
|---|---|---|
| `UNIGINE_BENCH` | `heaven` | `heaven` or `superposition` |
| `UNIGINE_WIDTH` / `UNIGINE_HEIGHT` | `QUASAR_STREAM_WIDTH/HEIGHT`, else `1920x1080` | render size |
| `UNIGINE_REFRESH` | `QUASAR_STREAM_FPS`, else `60` | gamescope output refresh |
| `UNIGINE_QUALITY` | `high` (heaven) / `medium` (superposition) | heaven: `low\|medium\|high\|ultra`; superposition: `low\|medium\|high\|extreme` |
| `UNIGINE_TESSELLATION` | `normal` | heaven only: `disabled\|moderate\|normal\|extreme` |
| `UNIGINE_PRESET` | `1080p_medium` | superposition only, becomes `PRESET_<upper>` |
| `UNIGINE_FULLSCREEN` | `1` | `-video_fullscreen` |
| `UNIGINE_LOOP` | `1` | restart the run when it exits |
| `UNIGINE_LOOP_GAP` | `5` | seconds between passes |
| `UNIGINE_MAX_PASSES` | `0` | `0` = unbounded |
| `UNIGINE_SOUND` | `null` | `-sound_app` |
| `UNIGINE_EXTRA_ARGS` | — | appended verbatim |
| `UNIGINE_DRY_RUN` | `0` | print the resolved command and exit; needs no GPU/X server |

**No baked resolution.** `UNIGINE_WIDTH`/`HEIGHT` are deliberately unset in the image: a baked value is non-empty and would shadow the session mode Quasar injects as `QUASAR_STREAM_*` (quasar#384), pinning every session to it. The same applies to an app row's `env` — leave resolution out of it unless you specifically want to decouple render size from stream size.

**Where results land.** Everything goes to the managed home (`org.quasar.image.persist=/home/quasar`), so the host can collect it from `/var/lib/quasar/homes/<user>/<app>/`:

- `~/unigine-bench/run-<UTC timestamp>/pass-NNN.log` — the pass's full stdout+stderr
- `~/unigine-bench/run-<UTC timestamp>/summary.jsonl` — one JSON object per pass
- `~/.Heaven/` and `~/.Superposition/` — the engine's own state

Every score line is *also* teed to the container's stdout prefixed `[unigine-result]`, so `docker logs` of the session container is a sufficient result channel on its own.

The engine rewrites its `engine_config` on exit, so `/opt/unigine/*/data` is world-writable in the image. That write lands in the container's ephemeral upper layer rather than the managed home, so every session starts from the pristine baked config — deliberate, and the reason runs are comparable.

**Building.** `WITH_SUPERPOSITION=1` is the default and adds ~1.7 GB extracted:

```sh
./scripts/build.sh quasar-unigine                       # Heaven + Superposition
WITH_SUPERPOSITION=0 ./scripts/build.sh quasar-unigine  # Heaven only, disk-constrained hosts
./scripts/verify-unigine.sh
```

The installers are pulled from `assets.unigine.com` at build time with pinned sha256 sums, into a BuildKit cache mount so a rebuild does not re-pull 1.9 GB. **This image is deliberately not published to GHCR** — it redistributes third-party binaries under their own EULAs — which is why its `quasar-manifest.json` entry is `kind: template` rather than `prebuilt`.

### Patched KWin (nested mode ladder)

`quasar-kde` does **not** ship Fedora's stock `kwin`. It rebuilds the distro source package with every `images/quasar-kde/kwin/*.patch` applied — in sorted `NNNN-` order, which is load-bearing because the patches build on each other — in discarded Dockerfile stages. Adding a patch is dropping a file in that directory; the Dockerfile copies the whole glob and the build script declares each one in the spec.

The rebuild is split across two stages so a patch edit does not re-buy the build dependencies: `kwin-deps` (`build-kwin-deps.sh`) fetches the pinned source package and installs ~1.5 GB of Qt/KF6 `-devel`, keyed only on `KWIN_BUILDER_BASE` + `KWIN_NVR`; `kwin-build` (`build-kwin.sh`) applies the patches and runs `rpmbuild`.

**The resulting RPMs are a reusable artefact, not just a stage.** The rebuild is 27 of the 35 minutes of a full CI run, and the RPMs are bit-identical whenever their inputs are, so a `FROM scratch AS kwin-rpms` stage carries them (~12 MB) under a content tag from `scripts/kwin-artifact-tag.sh` — a hash over `KWIN_NVR`, the digest-pinned `KWIN_BUILDER_BASE`, every `kwin/*.patch` and every `kwin/build-kwin*.sh`, and nothing else. `KWIN_RPMS_IMAGE` selects the source: its default `kwin-rpms` resolves to the local stage, so an ordinary build is unchanged, while `ghcr.io/accretion-io/quasar-kwin-rpms:<tag>` skips the rpmbuild stages entirely. CI publishes the artefact on a miss (never on a pull request — see `AGENTS.md`, "What CI does, per event") and reuses it thereafter.

| Patch | Makes work |
|-------|------------|
| `0001-nested-backend-mode-ladder.patch` | Display Settings → **Resolution** (a real mode ladder, and applying a pick) |
| `0002-nested-backend-kscreen-scale.patch` | Display Settings → **Scale** (the slider, under a host that implements `wp_fractional_scale_v1` — which Quasar's compositor does) |
| `0003-nested-backend-host-scale-hint.patch` | Quasar's per-session **`ui_scale`** (a changed host `wp_fractional_scale_v1` hint actually moves the nested output's scale, instead of being overwritten by KWin's own remembered configuration) |

**Why.** KWin runs nested here: it is a Wayland client of Quasar's compositor, and its output size comes from the host's `xdg_toplevel.configure`. Upstream's nested backend therefore synthesises exactly one output mode and throws the rest away (`src/backends/wayland/wayland_output.cpp`, in `init()`, `applyConfigure()` and `framePresented()`), and `applyChanges()` never reads `OutputConfiguration`'s `currentMode` at all. The visible result inside a Quasar session is that System Settings → Display lists a single resolution and choosing anything does nothing. Since this nested session *is* the desktop the user streams, "pick your internal resolution" has to work, so the backend is patched to advertise the host compositor's own `wl_output` mode ladder, honour a picked mode, and keep filling the host's area by scaling the content through `wp_viewport` (aspect-preserving, letterboxed). The patch header documents each change and the reasoning; read it before touching any of this.

**The recurring cost.** Every Fedora `kwin` update needs the patch re-diffed and the image rebuilt. This is deliberate and is the price of the feature; it is not a temporary hack awaiting cleanup (upstream has no interest in nested-backend mode setting).

Re-diffing on a kwin update:

1. Fetch the new source: `dnf download --source kwin` in a `fedora:43` container, then `rpm -i` it and unpack `SOURCES/kwin-<version>.tar.xz`.
2. Apply the current patches **in order**: `patch -p1 --dry-run < 0001-...patch`, then `0002-...patch`, then `0003-...patch`. If they apply clean, only the version bump is needed — rebuild and re-run `scripts/verify-kde.sh`.
3. If one rejects, port the hunks by hand against `src/backends/wayland/`. 0001 touches seven files; `wayland_output.cpp` carries the real logic (mode ladder, sticky user mode, `contentScale()`), and the other six are the mechanical consequences (host `wl_output` binding, layer/cursor placement, pointer mapping). 0002 and 0003 touch only `wayland_output.{cpp,h}` and are a handful of small hunks each.
4. Regenerate the patch(es), keeping the prose headers, and rebuild. To re-diff cleanly, keep an `a/` tree with the preceding patches applied and a `b/` tree with the one being re-diffed on top, then `diff -uNr a b`.
5. The artefact tag moves on its own — `./scripts/kwin-artifact-tag.sh --explain` shows what changed and the new tag. Rebuild it once (`./scripts/build.sh quasar-kwin-rpms`), or let the first publishing CI run build and publish it; every later run reuses it. A pull request that changes a kwin input deliberately pays the 27 minutes inline instead, because it is proving that build still works.

`scripts/verify-kde.sh` asserts `rpm -q kwin` carries the `.quasar` release marker, so a base-image refresh that quietly reinstates the stock package fails the build rather than shipping an inert Display KCM. It also runs a **functional** smoke — a nested `kwin_wayland` under a `--virtual` one — that changes the resolution *and* the scale and asserts both took effect, so a patch that applies with fuzz but no longer does anything fails the build too.

**Where the rungs come from.** The host compositor's own `wl_output` ladder is read and offered first. It is only a hint, though: the patched backend always commits a surface covering the host's configured area and scales the content into it, so any size at or below that is presentable against *any* host — which matters, because every headless parent advertises exactly one mode (KWin's own Wayland server included: `OutputInterfacePrivate::sendMode` only ever sends the current mode). The standard rungs in the host-configured size's aspect family are therefore offered as well, which is what makes the list useful today rather than after `gst-wayland-display` grows a ladder. `KWIN_NESTED_EXTRA_MODES=0` in the session environment restricts the list to the host's own ladder.

**Known limitation.** Rungs are only ever offered at or below the size the host configured the session at; the session cannot be made *larger* than its streamed resolution from inside. Changing the streamed resolution stays a Quasar-side control.

**Scale vs. the host's `wp_fractional_scale_v1` hint.** Precedence is *user pick > host hint, until the host hint moves*: a scale set in Display Settings sticks across the configures the host sends (Quasar sends one on every live render-resolution change), and is handed back when the host announces a genuinely different preferred scale. Setting the scale never touches the output **mode** — the buffer keeps the host-configured pixel size and the root `wp_viewport` destination is unchanged, so the streamed resolution does not move; only the logical desktop (`mode / scale`) shrinks, which is what makes Plasma redraw bigger.

Both halves of that sentence are patched behaviour. The hint half (0003) is what Quasar's per-session **`ui_scale`** drives: `gst-wayland-display` shrinks the logical size it configures the toplevel at *and* announces the matching preferred scale, so the hint means "draw bigger at an unchanged streamed resolution" here rather than the protocol's usual "render crisper at the same apparent size". Writing the hint into the output's state is not enough on its own, because `applyConfigure()` emits `outputsQueried`, and KWin core answers that by re-applying `OutputConfigurationStore`'s *remembered* configuration — `~/.config/kwinoutputconfig.json`, scale included — which overwrites it a moment later. 0003 therefore adopts a changed hint through `Workspace::applyOutputConfiguration()`, the same path a slider pick takes, so it is remembered rather than reverted.

## Published images

Branching model: **`stable` is the default and published branch; `develop` is the persistent integration branch.** Use manual workflow dispatch on `develop` to build and publish each image to `ghcr.io/accretion-io/<image>:develop` and an immutable `sha-<commit>` tag. Pushes to `stable` build and publish `:latest` and the same immutable SHA tag automatically. Pull requests build only; ordinary `develop` pushes do not trigger a workflow.

The workflow fans out over the DAG — a sequential `spine` job (`quasar-base` → `quasar-app` → `quasar-steam-runtime`) followed by the leaves in parallel — and shares one build/verify/publish definition between validation and publishing. **Which images are published is `build-graph.json`'s `publish` flag**, not a list in the workflow. A pull-request run never receives `packages: write`, because it executes the scripts and Dockerfiles from the PR; the full per-event table, and why the jobs are deliberately doubled rather than parameterised, is in `AGENTS.md`.

`quasar-manifest.json` at the repository root is the **app-image catalog manifest** the Quasar control plane consumes (`GET /v1/admin/images`, `POST /v1/admin/images/sync`). It is a contract surface — Quasar refuses a `manifest_version` it does not understand. See `MANIFEST.md` before editing it.

When a launch provides `QUASAR_GPU_VULKAN_DEVICE_UUID`, `quasar-app` fails closed unless Vulkan selects that exact hardware UUID. Without it (the Quasar agent does not ship GPU-UUID assignment yet — quasar#273) the probe still rejects software renderers but accepts whichever hardware device the runtime injected. PCI-BDF validation is added when Quasar's companion GPU-assignment transport exposes the mapping.
