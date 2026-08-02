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
cmdline token match). The reaper process alone is **not** treated as the
exit signal: Steam drops it during a title's own startup for title-specific
durations (Redout ~1s, Hades II >4s, live-observed on Tower 2026-08-02), so
process-liveness cannot distinguish a real quit from a game's own internal
hand-off. The watcher's debounce loop instead arbitrates on Steam's own
`RunningAppID` in `~/.steam/registry.vdf` — set at launch and held across
every hand-off a title makes to itself, clearing within ~1-2s of a real
quit. Once the exit is registry-confirmed (or, as a bounded safety valve,
the process stays gone long enough that a wedged registry is trusted
instead), the watcher invokes the same graceful-shutdown relay used for
`docker stop` (see above) so the container exits 0 and the session ends
cleanly. See `docs/design/plans/2026-08-02-steam-game-exit-lifecycle-spec.md`
in the `quasar` repo for the full design (Phase A, this image; Phase B,
richer launch-state reporting to the control plane, is a separate
frozen-interface amendment and not implemented here).

Knobs:

| Variable | Default | Effect |
|---|---|---|
| `QUASAR_STEAM_EXIT_ON_GAME_EXIT` | `1` | Set to `0` to disable the watcher entirely (operator/debug escape hatch), even when a valid `-applaunch <appid>` pair is present. A session without a valid pair never arms the watcher regardless of this knob — that is what makes a launcher-tile session unaffected. |
| `QUASAR_STEAM_GAME_EXIT_DEBOUNCE` | `8` (seconds) | How long the watcher waits, after the reaper process is no longer detected, before checking the Steam registry's arbitration verdict. A reappearing reaper (CEF shims, anti-cheat relaunchers, Proton restarts) during this window resets the watcher back to "running" instead of tearing down the session. At each expiry, if the registry (`RunningAppID`) has cleared, the exit is confirmed; if it still reports the watched appid, the window is extended by another `QUASAR_STEAM_GAME_EXIT_DEBOUNCE` seconds (a long startup hand-off, not registry lag) up to the `QUASAR_STEAM_EXIT_REGISTRY_CAP` total. Raise per-app for titles whose launcher shims respawn slowly. (Was 15/single-4s-extension at first ship; retuned 2026-08-02 to registry arbitration after live Tower testing showed the reaper-process signal alone blinks the client's loader — Redout — or races a slow title's own hand-off into a kill — Hades II.) |
| `QUASAR_STEAM_EXIT_REGISTRY_CAP` | `24` (seconds, beyond the first debounce expiry) | Total additional time, on top of the first `QUASAR_STEAM_GAME_EXIT_DEBOUNCE` window, the watcher will keep extending the debounce while the registry still reports the watched appid running. This is the safety valve for a crashed/hung game whose registry entry never clears: once the cap is exhausted, the watcher trusts the process signal (reaper gone) and confirms exit anyway, logged distinctly ("registry still reports appid ... after Ns; trusting process signal") so the fallback path is identifiable in the field. A process reappearance at any point during the extended window still returns the watcher to "running" before the cap is ever reached. |
| `QUASAR_STEAM_FOREGROUND_CHECK` | `1` | Foreground gate (Phase B, spec §B.1 "Foreground polish"): before the watcher advances `waiting_for_start` → `running`, it requires gamescope's X root atoms (`GAMESCOPECTRL_BASELAYER_APPID`, or the topmost window's `STEAM_GAME`, read via `xprop -root`) to corroborate the title is actually on screen, not just alive as a process. If unconfirmed within 10 s of the process first appearing, the watcher falls back to process-only and advances anyway — a title gamescope never tags must still reveal, never wedge. Set to `0` to skip the atom check entirely (process-only, exactly Phase A behaviour). Also degrades to process-only automatically when there is no `$DISPLAY` (the `QUASAR_STEAM_GAMESCOPE=0` path) or `xprop` is not present in the image. The debounce/exit side of the watcher is unaffected — process death is still the exit trigger; this gate only affects entering `running`. |

## Session state-file reporting (Phase B)

When the node-agent wants launch-state reporting it bind-mounts a per-session
directory into the container (read-write for the container's uid) at
`/run/quasar/session`. The watcher (and, for `client_only`, the launcher
itself as soon as the Steam client is backgrounded, but only when the watcher
is armed) writes a single line to `/run/quasar/session/app-state`, atomically
(`printf > tmp && mv`, tmp file in the same directory so the rename is
same-filesystem):

| State | Written when |
|---|---|
| `client_only` | Written twice, both meaning "the intermediary client is up, the target title is not currently running": (1) by the launcher itself as soon as the Steam client is backgrounded, when the watcher is armed (a valid `-applaunch <appid>` pair), before the game is first detected (pre-launch/arm time); and (2) by the watcher, from inside the `debounce` state on the **first debounce tick the Steam registry's `RunningAppID` no longer matches the watched appid** — Steam-confirmed, not merely "process not currently seen" (2026-08-02 redesign: the reaper process alone is not trustworthy here, since Steam drops it during a title's own startup hand-offs — Redout ~1s, Hades II >4s, live-observed on Tower — which is not a real quit). Written exactly once per debounce cycle, not on every tick. A launcher tile (watcher unarmed, no `-applaunch`) writes nothing at all — `app_launch_state` stays absent, so every consumer treats the session exactly as pre-spec. Writing `client_only` unconditionally (regardless of arming) was tried and reverted: an unarmed session would report a state it can never advance past, and a client waiting on `game_running` would hold indefinitely (live-measured as a 120s loader hold on a plain Big Picture session). Writing it immediately on `running` → `debounce` entry (process-gone, pre-registry-check) was also tried and reverted 2026-08-02: it blinked the client's loader on Redout's ~1s startup hand-off and, on Hades II's >4s hand-off, raced the client's respawn window into a kill. |
| `game_running` | The watcher's state machine enters `running` — both on first detection (subject to the foreground gate above) and on a debounce-window respawn (`debounce` → `running`), which un-masks the client again after a `client_only` write. |
| `game_exited` | The watcher confirms exit, written *before* it self-signals (`SIGUSR1`) the main launcher process, so the agent's final teardown read of the file sees the true outcome. |

If `/run/quasar/session` does not exist or is not writable (an older agent, or
a plain `docker run` with no mount), every write silently no-ops — zero
behaviour change. Absence of the file itself means "unknown" to any consumer.
This is a generic, Quasar-owned protocol (`/run/quasar/session` is not
Steam-specific); other app images can adopt the same single-file convention.

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
