# quasar-benchapp

The **instrument**, as opposed to `quasar-unigine`, which is the **workload**.

`quasar-unigine` gives Quasar a real 3D scene that costs the encoder something, but a
Heaven frame is opaque: nothing in the picture tells you which rendered frame you are
looking at, so there is no way to attribute a browser-received frame back to the frame
the app submitted. `quasar-benchapp` closes that gap. Every frame it renders carries an
opaque black-and-white luma marker encoding:

| field | width | why |
|---|---|---|
| `frame_index` | u32 | attribute a received frame to a rendered one; detect drops and duplicates definitively |
| `host_time_ms` | u48 | `CLOCK_REALTIME` unix ms at submission — the join key against encoder, network and browser telemetry |
| `scene_id`, `load_level` | u8, u8 | what was actually rendering, per frame, without trusting the launch config |
| `event_flags` | u8 | input-echo pulse, scene change, resolution change, labelled mark |
| `render_w`, `render_h` | u16, u16 | internal render size, so a resolution change is visible in the pixels |
| `crc16` | u16 | CRC-16/CCITT-FALSE — the authoritative integrity check after lossy transport |

Plus two auxiliary blocks: a **heartbeat** square that toggles every frame (cheap
drop/duplicate detection without a full decode) and an **input-echo** square that lights
for N frames on any keyboard/pointer/gamepad event (input-to-photon latency).

Layout and decoders are specified in the source repo: `docs/marker-spec.md`,
`tools/marker_decode.py` (still images), `tools/marker_decode.js` (browser `ImageData`).

## The one structural difference from every other app image

**There is no nested compositor here.** `quasar-steam` and `quasar-unigine` both ship
gamescope because their payloads are X11/GLX clients that need a bridge. benchapp is a
native Wayland `xdg_toplevel` and binds the node-agent's compositor socket directly.

That is not a simplification, it is the point: benchapp exists to measure the
compositor → encoder path, and a nested gamescope would insert a second compositor's
frame pacing and scaling into exactly the path under measurement. `verify-benchapp.sh`
asserts that gamescope and Xwayland are **absent** so a future base-image change cannot
quietly reintroduce them.

Consequently the launcher does **not** repoint `XDG_RUNTIME_DIR` the way the gamescope
images do — it keeps the node-agent's handover exactly as given.

## Build

The payload comes from the separate, currently unpublished `quasar-benchgame` repo, so
the build is two steps:

```sh
# 1. in the quasar-benchgame checkout
docker build -t quasar-benchapp:src .

# 2. here
QUASAR_IMAGE_TAG=dev ./scripts/build.sh quasar-benchapp
./scripts/verify-benchapp.sh --no-build
```

`BENCHAPP_SRC_IMAGE` overrides the source-stage image; `BENCHAPP_GIT_SHA` is recorded in
the `org.quasar.benchapp.git-sha` label. This is why the manifest entry is
`kind: template` with no `registry_ref` — nothing to pin until the source repo is
published.

## Knobs

All the app's own `BENCHAPP_*` variables pass through (see the source repo's README for
the full table). What this image decides on top:

| variable | image default | why |
|---|---|---|
| `BENCHAPP_SCENE` | `flythrough` | moving 3D geometry — the closest analogue to a game, and the default the app row uses |
| `BENCHAPP_LOAD` / `BENCHAPP_MOTION` | `5` / `5` | mid-dial, leaves headroom in both directions |
| `BENCHAPP_FPS` | *unset* → `QUASAR_STREAM_FPS` → 60 | the session's negotiated refresh is the correct pacing target |
| `BENCHAPP_RENDER` | *unset* | unset means "render at the compositor's configure size", which is what makes the probe follow live resolution changes (quasar#384). A baked value would pin it for every session and defeat the resolution-ladder tests. |
| `BENCHAPP_MARKER_SCALE` | `0.5` | see below |
| `BENCHAPP_DURATION_S` | `0` | run until the session ends |
| `BENCHAPP_OUT` | `~/benchapp/run-<ts>` | managed home, so the host can collect it |
| `BENCHAPP_CONTROL_FILE` | `~/benchapp/control.jsonl` | truncated at launch — see below |
| `BENCHAPP_CONTROL_SOCK` | `~/benchapp/control.sock` | |

### Why marker scale 0.5 and not the app's own 1.0

The marker canvas is 30×19 cells at `max(16, floor(surface_h * 0.03 * scale))` px per
cell. At scale 1.0 on a 1080p surface that is a **960×608 block — 28% of the frame
area** — of high-contrast black and white that changes every frame. That is a large,
codec-hostile constant added to every encoder-difficulty number measured with this
image, and it would swamp the differences between the scenes it is meant to compare.

At 0.5 the cell size hits its 16 px floor and the block is 480×304 (7% of area), and it
still decodes with a **valid CRC after a 1080p→720p downscale at 2 Mbps** (confidence
0.97, verified with ffmpeg/libx264). 0.5 is the better default; raise it if a run is
expected to survive an unusually harsh downscale.

### The control file is truncated at launch

`~/benchapp/control.jsonl` is recreated empty on every launch. The app's file reader
keeps a byte offset and only replays from zero on truncation, so without this a previous
session's queued commands would be replayed into the next one — a stale
`{"scene":"swarm"}` silently invalidating a static-scene measurement is precisely the
kind of error that leaves no trace in the results.

Drive it by appending, from the host:

```sh
docker exec <session-container> sh -c \
  'printf "%s\n" "{\"scene\":\"swarm\"}" >> /home/quasar/benchapp/control.jsonl'
```

## Output

Two channels, both real:

- **Container stdout** — one `[benchapp] fps=… frame_p95_ms=… gpu_p95_ms=… scene=… load=…`
  line per second, a `[benchapp-launch] …` line at start, and `[benchapp-result] {json}`
  on graceful exit.
- **The managed home**, at `/var/lib/quasar/homes/<user>/<app>/benchapp/run-<ts>/`:
  `frames.jsonl` (one record per presented frame), `events.jsonl` (commands, input,
  resize, cuts, marks), `summary.json` (rewritten atomically every 30 s and at exit).
  `~/benchapp/latest` symlinks the current run so a collector need not glob.

  Glob for a collector: `benchapp/run-*/{frames,events}.jsonl`.

### Graceful shutdown is supervised, not exec'd

The app installs no `SIGTERM` handler — its only graceful exits are `--duration-s`
elapsing and a `{"quit":true}` command. A plain `docker stop` would therefore kill it
mid-write with no final `summary.json`. The launcher runs it as a child and, on
`SIGTERM`, appends the quit command it *does* understand, then waits
`BENCHAPP_TERM_GRACE_S` (default 8 s) before escalating. `frames.jsonl` and
`events.jsonl` flush at least once per second regardless, so only the final summary and
the last sub-second of frames were ever at risk — but the summary is the cheapest thing
for a harness to read.
