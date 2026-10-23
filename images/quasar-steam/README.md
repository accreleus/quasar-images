# quasar-steam

Steam in nested Gamescope on the shared `quasar-app` Fedora runtime. Steam is
installed from RPM Fusion; RPM Fusion, the 32-bit graphics stack, Gamescope, and
a games-on-whales-derived Bubblewrap workaround are layered on top. It launches
Steam in a game-console experience by default and deliberately excludes Decky,
host input mounts, and service daemons because Quasar owns those policies.

## Game foreground / focus (the important part)

Pressing **Play** must bring the launched game to the foreground. In nested
Gamescope this is driven entirely by X11 atoms, not process ancestry:

- Each game window is tagged with the `STEAM_GAME` appID property by the Steam
  Runtime; Gamescope focuses a tagged game window over the Steam UI.
- In modern **gamepadui** (Deck) mode Steam additionally manages
  `GAMESCOPECTRL_BASELAYER_APPID` on the root window. If Steam runs gamepadui
  **without** the full SteamOS session flags, it pins the baselayer to its own UI
  (appID `769`) and never hands focus to launched games — the Play button just
  turns into Resume while the screen stays on Steam. This was the original defect.

The launcher (`quasar-steam`) bakes in no UI-mode default. The plain Steam app's
UI mode comes from the catalog's Steam runtime preset, which carries
`STEAM_STARTUP_FLAGS=-bigpicture`; a derived game tile overrides that env with
its own flags, and once #728 drops `-bigpicture` from the tile flags, quick
launch will run with no Big Picture. With `STEAM_STARTUP_FLAGS` and
`QUASAR_STEAM_UI_MODE` both unset, Steam starts with no UI-mode flag, and the
launcher logs a warning (a derived tile's `-applaunch` flags do not warn).
`QUASAR_STEAM_UI_MODE` still selects one of two **validated** configurations as
an explicit opt-in. To opt in to gamepadui on an app whose preset already
carries `STEAM_STARTUP_FLAGS`, set the full gamepadui flag set as
`STEAM_STARTUP_FLAGS` on the app — the preset's flags win over the mode, so
`QUASAR_STEAM_UI_MODE=gamepadui` alone would otherwise leave a partial unit.

| `QUASAR_STEAM_UI_MODE` | Steam flags | `STEAM_MULTIPLE_XWAYLANDS` | Notes |
|---|---|---|---|
| *(unset)* | *(none)* | off | No UI-mode flag. For the plain Steam app it means a Steam app that does not use the preset the Steam image installed, without the flag (the launcher warns). |
| `bigpicture` | `-bigpicture` | off | Legacy Big Picture. Does not pin the baselayer; games come forward via the default focus. games-on-whales-validated. |
| `gamepadui` | `-gamepadui -steamos3 -steampal -steamdeck` | on | Modern Deck UI. Full SteamOS session unit (matches Valve's gamescope-session). Never shipped partially. |

`STEAM_STARTUP_FLAGS` overrides the computed flags verbatim (advanced use).
The `STEAM_MULTIPLE_XWAYLANDS` default follows the effective flags — on only
when they contain the full gamepadui unit; `QUASAR_STEAM_MULTIPLE_XWAYLANDS` (`0`/`1`)
overrides that default.
Set `QUASAR_STEAM_GAMESCOPE=0` to run Steam without nested Gamescope.

Before Steam starts, the launcher turns on Steam's background shader processing
(`ShaderCacheManager` → `EnableShaderBackgroundProcessing` `1` in
`~/.local/share/Steam/config/config.vdf`), but only when that key is absent: a value the
user set, either way, is never touched. A home with no `config.vdf` yet is skipped (Steam
creates it; the next start sets the key), as is a file that is not Steam's KeyValues text
form, and the file is only ever replaced by a same-directory rename. Set
`QUASAR_STEAM_SHADER_BACKGROUND=0` to skip the step.

## Display mode

**Starting mode.** Gamescope's nested output starts at `QUASAR_STREAM_WIDTH` /
`QUASAR_STREAM_HEIGHT` / `QUASAR_STREAM_FPS`, which Quasar injects per session
from the launched stream profile (quasar#384). An explicit `GAMESCOPE_WIDTH` /
`GAMESCOPE_HEIGHT` / `GAMESCOPE_REFRESH` overrides it (per-app pin). With
neither set, the image falls back to 1920x1080x60.

**A game's resolution pick stays inside the session.** In a nested session
gamescope's output is the session's streamed mode, and a game that asks for a
different resolution is scaled inside that output, as upstream does; the
monitor's modes are not visible to the game and the host is never asked to move.
Gamescope's Xwayland is the system one. To change the display a console session
runs at, use direct display (below), where gamescope drives the monitor itself.

## Direct display (console sessions, quasar#453)

With `QUASAR_DIRECT_DISPLAY=1` gamescope drives the monitor itself on its DRM
backend instead of nesting in the agent's compositor. Steam Big Picture runs on
top exactly as in a nested session. Any other value, or none, is the nested
behaviour above, unchanged.

What you need (the agent's run shape): `--network host` (udev hotplug),
`--gpus all -e NVIDIA_DRIVER_CAPABILITIES=all`, `--device /dev/dri`,
`--device /dev/snd`, `-v /dev/input:/dev/input` with
`--device-cgroup-rule 'c 13:* rwm'` (replugged devices),
`-v /run/udev/data:/run/udev/data:ro -v /run/udev/control:/run/udev/control:ro`,
`--cap-add SYS_NICE`, `--shm-size 1g`, `--security-opt seccomp=unconfined`, the
container's root as the entrypoint user (PUID/PGID as usual). No parent Wayland
socket and no `PULSE_SERVER`.

What the image does:

- `25-steam-direct-seatd.sh` starts `seatd` as the container's root, not
  VT-bound, with `/run/seatd.sock` owned by the app user and group. gamescope
  reaches it through libseat (`LIBSEAT_BACKEND=seatd`); seatd opens the card and
  input nodes for it.
- `24-steam-direct-device-groups.sh` makes the app user a member of the groups
  owning `/dev/input/event*`, `/dev/hidraw*` and `/dev/snd/*`: Steam Input reads
  physical controllers itself, and sound plays on the console's card (gamescope's
  own devices still come through seatd). Never gid 0 or 65534. It never changes a
  node: `/dev/input` is the host's directory, and quasar-base's
  `15-input-device-perms.sh` does nothing in this mode either.
- The launcher starts `gamescope --backend drm -e` at the panel's native size and
  highest refresh: the preferred mode's size, and the highest refresh the kernel
  lists at that size (read with `drm_info -j`). It names a mode only when exactly
  one connector is connected; otherwise gamescope picks its preferred mode.
  `QUASAR_STEAM_DIRECT_ARGS` (e.g. `-W 2560 -H 1440 -r 165`) replaces the
  detected mode.
- On `nvidia-drm` it adds `--force-composition` and `gamescope_drm_gbm_scanout=1`:
  GBM-allocated scanout buffers (`gamescope-gbm-scanout.patch`), the fix for a
  corrupt band at the bottom of every 4K mode on the NVIDIA driver (upstream
  [gamescope#2309](https://github.com/ValveSoftware/gamescope/issues/2309)).
  `QUASAR_STEAM_GBM_SCANOUT=1|0` forces it on or off.
- Sound: the launcher drops any `PULSE_*` it was given and runs Steam as
  `dbus-run-session -- /usr/local/libexec/quasar-steam/direct-session`, which
  starts PipeWire, WirePlumber and `pipewire-pulse` in that session bus (with the
  private `XDG_RUNTIME_DIR`) and then execs Steam. WirePlumber picks the default
  output; Steam's Settings > Audio lists the others. A nested session starts none
  of this and keeps the agent's `PULSE_SERVER`.
- The nested-only pieces (`QUASAR_STREAM_*`, `GAMESCOPE_WIDTH/HEIGHT/REFRESH`) are
  not used.

How to know it worked: the log has `seatd ready: /run/seatd.sock`,
`audio: PipeWire, WirePlumber and the PulseAudio shim started`, then
`starting Gamescope on the display (direct; ... 3840x2160@240 ... gbm_scanout=1 ...)`,
and gamescope's own `Overriding from environment variable: gamescope.convars.drm_gbm_scanout.value = 1`.

## Launch helper (quasar#731)

For a Steam game tile, Quasar's node agent mounts its report-only launch helper and
sets `QUASAR_LAUNCH_HELPER` and `QUASAR_LAUNCH_SOCKET`. Once gamescope reports ready
the launcher starts the helper, and Steam waits for the helper's `ready` line, at most
2 s: the helper decides on its first look where to start reading Steam's log. A helper
that dies is started again, at most 3 times a minute. On a host that mounts `/run`
noexec the mount cannot be executed, so the launcher runs a copy from its private
runtime directory. With the variable unset, nothing changes.

## Host / launch requirements

The image cannot set these itself; the Quasar agent (or a manual `docker run`)
must provide them.

1. **`--shm-size=1g`.** Steam's Chromium command buffers need a large `/dev/shm`.
   Docker's 64 MB default yields a black/flashing UI. The launcher logs a warning
   when `/dev/shm` is below 256 MiB.

2. **32-bit NVIDIA driver libraries (NVIDIA hosts).** Steam and most games are
   32-bit and need 32-bit GL/Vulkan userspace. **The image does not bake driver
   libs** — they are coupled to the exact host driver version and would make the
   image unshippable. The container runtime must inject the 32-bit driver libs:
   - NVIDIA Container Toolkit / CDI with `NVIDIA_DRIVER_CAPABILITIES` including
     `graphics` (and `compat32` so the 32-bit libs are mounted), **or**
   - bind-mount the host's 32-bit NVIDIA userspace into the container.

   The 64-bit runtime alone is not enough. The launcher warns when 64-bit NVIDIA
   GL is present but the 32-bit `libGLX_nvidia.so.0` was not injected. The
   `quasar-gpu-init` hook runs `ldconfig` at start so injected libs are picked up.

3. **Audio (PulseAudio).** The agent injects `PULSE_SERVER`, `PULSE_COOKIE`, and
   `PULSE_SINK` (sink `quasar_output`). PulseAudio-aware clients use them
   directly. As belt-and-braces the base `quasar-app` ships
   `alsa-plugins-pulseaudio` + `/etc/asound.conf` so ALSA-only clients (Steam's
   Chromium AudioService when it falls back to ALSA) also route to Pulse. No
   Quasar paths are hardcoded — the route honours `PULSE_SERVER` from the
   environment.

4. **PUID/PGID.** The image honours the base `quasar-entrypoint` PUID/PGID
   convention (e.g. unraid's `99:100`): run as root and pass `PUID`/`PGID` and the
   entrypoint drops to that user via `setpriv`. Steam state lives under `$HOME`.

## In-container system services (D-Bus + NetworkManager): off for Steam

`quasar-steam-runtime` ships `/etc/quasar/init.d/20-steam-system-services.sh`,
which starts a **D-Bus system bus** and **NetworkManager** inside the container
(the KDE and XFCE images keep them on: Plasma's network applet and Discover read
NM). This image sets `QUASAR_STEAM_SYSTEM_SERVICES=0`, so Steam runs with
neither (quasar#741).

Why off: Steam's login sits in `WaitingForNetwork` until some network device has
an IPv4 default route, and it reads that flag from NetworkManager's
`ActiveConnection.Default`. NM in a container has no `NET_ADMIN`, so it only
*observes* the interface docker configured ("connected (externally)"), and NM
never picks an externally managed device as the default. The flag stays false,
and every sign-in waited out Steam's timeout: 10 s in Big Picture, 20 s under
`-silent` (`steamui_login.txt`: `Timed out waiting for network`). With no NM
client Steam skips the wait and signs in at once.

The first reason for these services (quasar-images#4: Big Picture's
`SystemNetworkStore` threw without `SteamClient.System.Network.*` and the UI hung
on "Waiting for network" forever) is gone: current Steam checks for those
bindings before using them.

`QUASAR_STEAM_SYSTEM_SERVICES=1` (in the runtime preset's env) brings both
services back, for A/B debugging.

## Build & verify

```sh
./scripts/build.sh quasar-steam
./scripts/build.sh verify quasar-steam   # verify-steam.sh + verify-steam-launcher.sh
```

`verify-steam-launcher.sh` runs the launcher and the direct-display hooks inside
the image with stub `gamescope`/`dbus-run-session`/`drm_info` (cases and
`drm_info` fixtures in `scripts/tests/steam-launcher/`), so the nested command line
and the direct one are both pinned without a GPU.
