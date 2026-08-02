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

The launcher (`quasar-steam`) selects one of two **validated** configurations via
`QUASAR_STEAM_UI_MODE`:

| `QUASAR_STEAM_UI_MODE` | Steam flags | `STEAM_MULTIPLE_XWAYLANDS` | Notes |
|---|---|---|---|
| `bigpicture` (default) | `-bigpicture` | off | Legacy Big Picture. Does not pin the baselayer; games come forward via the default focus. games-on-whales-validated, robust default. |
| `gamepadui` | `-gamepadui -steamos3 -steampal -steamdeck` | on | Modern Deck UI. Full SteamOS session unit (matches Valve's gamescope-session). Never shipped partially. |

`STEAM_STARTUP_FLAGS` overrides the computed flags verbatim (advanced use).
`QUASAR_STEAM_MULTIPLE_XWAYLANDS` (`0`/`1`) overrides the per-mode default.
Set `QUASAR_STEAM_GAMESCOPE=0` to run Steam without nested Gamescope.

Display mode: gamescope's nested output is sized from `QUASAR_STREAM_WIDTH` /
`QUASAR_STREAM_HEIGHT` / `QUASAR_STREAM_FPS`, which Quasar injects per session
from the launched stream profile (quasar#384). An explicit `GAMESCOPE_WIDTH` /
`GAMESCOPE_HEIGHT` / `GAMESCOPE_REFRESH` overrides it (per-app pin); with
neither set the image falls back to 1920x1080x60. This is what Steam and every
game it launches see -- it is not derived from the host compositor's output,
which nested gamescope does not read.

## Game-exit lifecycle (derived tiles)

A **derived tile** (a "game" tile that launches straight into a title via
`-applaunch <appid>`, e.g. `STEAM_STARTUP_FLAGS="-bigpicture -applaunch
620"`) is understood to *be* that game: when the game exits, the session
should end rather than fall back to Big Picture. A **launcher tile** (plain
Big Picture, no `-applaunch`) is unaffected either way — the user is
expected to browse and launch titles from inside Steam, so exiting a game
launched from there returns to Big Picture as before.

The launcher implements this with an in-container watcher: once armed (a
valid `-applaunch <appid>` pair was parsed from `STEAM_STARTUP_FLAGS`), it
polls for the title's Steam `reaper` wrapper process (exact `AppId=<appid>`
cmdline token match, corroborated by `RunningAppID` in
`~/.steam/registry.vdf`) and, after the game is confirmed gone (with a
debounce for shim/launcher titles that legitimately relaunch), invokes the
same graceful-shutdown relay used for `docker stop` (see above) so the
container exits 0 and the session ends cleanly. See
`docs/design/plans/2026-08-02-steam-game-exit-lifecycle-spec.md` in the
`quasar` repo for the full design (Phase A, this image; Phase B, richer
launch-state reporting to the control plane, is a separate frozen-interface
amendment and not implemented here).

Knobs:

| Variable | Default | Effect |
|---|---|---|
| `QUASAR_STEAM_EXIT_ON_GAME_EXIT` | `1` | Set to `0` to disable the watcher entirely (operator/debug escape hatch), even when a valid `-applaunch <appid>` pair is present. A session without a valid pair never arms the watcher regardless of this knob — that is what makes a launcher-tile session unaffected. |
| `QUASAR_STEAM_GAME_EXIT_DEBOUNCE` | `15` (seconds) | How long the watcher waits, after the reaper process is no longer detected, before treating the game as exited. A reappearing reaper (CEF shims, anti-cheat relaunchers, Proton restarts) during this window resets the watcher back to "running" instead of tearing down the session. If the window expires but the Steam registry still reports the title as the running app, the watcher extends once by one more window before trusting the process signal and confirming exit. |

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

## Build & verify

```sh
./scripts/build.sh quasar-steam
./scripts/verify-steam.sh
```
