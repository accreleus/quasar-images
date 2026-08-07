# quasar-manifest.json — the Quasar app-image catalog contract

`quasar-manifest.json` is the machine-readable catalog the Quasar control plane fetches
(pinned by ref) and caches. It is **a contract surface**: Quasar parses it, so a breaking
change here breaks deployments that sync. It is versioned; Quasar refuses a `manifest_version`
it does not understand rather than partially applying it.

Full design lives in the Quasar repo: `docs/design/plans/2026-08-07-image-management-spec.md`.

## Fields (manifest_version 1)

Top level: `manifest_version` (int), `images` (array).

Each image:

| field | req | meaning |
|---|---|---|
| `id` | yes | Stable identifier. **Never reuse an id for a different image.** |
| `display_name` | yes | Shown in the admin catalog. |
| `description` | | Longer text. |
| `kind` | yes | `prebuilt` (pull `registry_ref`) or `template` (build locally — a later Quasar phase). |
| `version` | yes | The image's CalVer `YYYY.MM.DD[.N]` — when this image was released. App images track upstream software with no meaningful semver of its own, so a date is honest where `1.2.0` would be fiction. "Update available" = this value moved, which is always a deliberate edit here. |
| `registry_ref` | prebuilt | Concrete, immutable image reference (a `sha-<commit>` or digest tag, never `:latest`/`:develop`). |
| `dockerfile` | template | Path within this repo. (Reserved; template builds are a later phase.) |
| `build_args` | template | Build args. |
| `artwork` | | Paths within this repo (e.g. `{ "tile": "images/.../tile.png" }`). |
| `library_provider` | | Set when this image IS a provider's canonical image (e.g. `steam`). Enabling that provider in Quasar auto-ensures this image. |
| `runtime` | yes | The default runtime configuration Quasar lands when the image is installed (below). |
| `notes` | | Free text for operators/maintainers. |

## runtime mapping — read this before editing a `runtime` block

The `runtime` block is a **superset** of two distinct Quasar objects, and they are stored in
different places:

- `preset_name`, `args`, `env`, `mounts`, `managed_home`, `home_container_path`, `gpu` map to a
  Quasar **runtime preset** (`runtime_presets` table — first-class columns).
- `no_new_privileges` (and other future security knobs) ride the app's **`runtime_spec`** JSONB
  blob, NOT the preset columns. Quasar resolves the split when it installs an image; the
  manifest states the whole intended runtime and lets Quasar place each field correctly.

`no_new_privileges` is **security-relevant and load-bearing**: Steam must have it `false`
(its startup re-escalates via `sudo`; the default hardened `--security-opt no-new-privileges`
otherwise yields a black bare compositor). Because this file is fetched and applied by every
syncing deployment, treat any change to a security knob here as a reviewed change.

## Pinning discipline

`registry_ref` and `version` are always concrete. Publishing a new build of an image is a
deliberate act: bump `version` + `registry_ref` in this file. Quasar never sees a tag repoint
under it — an update is only ever an explicit manifest change.
