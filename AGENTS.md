# AGENTS.md — operating this repository

Durable context for anyone (human or AI agent) changing `quasar-images`. Read it
before editing. `README.md` explains what each image *is*; this explains how the
build works and what will bite you.

Sibling docs: `MANIFEST.md` (the `quasar-manifest.json` catalog contract, a
consumer-facing surface) and each image's own `Dockerfile`, which is where the
per-image reasoning lives and where it should stay.

## The one rule

**`build-graph.json` is the only place the image set is stated.** Build order,
build args, verify wiring, what CI builds, what gets published — all of it. Two
things read it, both through `scripts/graph.sh`: `scripts/build.sh` and
`.github/workflows/image-build.yml`.

Before it existed the same knowledge lived in a bash `case` statement and a
hardcoded `for image in ...` list in the workflow, and they had already drifted.
If you find yourself adding an image name to a script or a workflow, stop — the
name belongs in the graph.

## The build DAG

```
quasar-base ── quasar-app ─┬─ quasar-steam-runtime ─┬─ quasar-steam
    (spine)      (spine)   │        (spine)         └─ quasar-kde
                           ├─ quasar-diagnostics
                           ├─ quasar-benchapp
                           ├─ quasar-test-vulkan
                           ├─ quasar-test-egl
                           └─ quasar-unigine        (local only, never in CI)

quasar-kwin-rpms   an ARTIFACT, not an image: the patched-KWin RPM bundle that
                   quasar-kde consumes (see "The KWin artefact")
quasar-probe       not in the graph at all: the Quasar node-agent builds it as a
                   template image; nothing here builds it
```

**spine vs leaf** is not decoration. The spine is the ancestry every leaf
inherits, and CI builds it in one sequential job *before* the leaves fan out, so
its layers are in the shared cache when they start. Without that, N parallel leaf
jobs each rebuild `quasar-base` + `quasar-app` from cold.

`quasar-unigine` is `ci: false` deliberately: it pulls 1.9 GB of EULA'd UNIGINE
installers and is never published, so CI would spend the download and the disk on
something it can neither publish nor hand to anyone. It stays in `build.sh all`
for local builds, where a BuildKit cache mount makes the download a one-off.

## Adding a new image

1. Write `images/<name>/Dockerfile`.
2. Add an entry to `build-graph.json`, **after** every image it `needs` (file
   order is the build order, and `graph.sh check` enforces it — that is what
   makes a dependency cycle inexpressible).
3. If it has a verify script, list it in `verify` and make the script
   executable. It will then run locally *and* in CI. Nothing else to wire.
4. `./scripts/build.sh check` — validates dockerfile paths, tiers, dependency
   ordering, a `ci: true` image on a `ci: false` parent, verify scripts, and the
   `args` vocabulary: an unknown `@resolver`, an `@tag:` naming an image that is
   not in the graph, or an `@tag:` whose target is missing from `needs` (the two
   fields state the same dependency, and drift between them is a build that dies
   minutes in on a parent that was never built).
5. `./scripts/build.sh <name>` — builds it and its ancestors.

Arg values in the graph use four forms and nothing else: `@version` (the
`VERSION` file), `@tag:<image>` (a sibling), `@env:NAME=DEFAULT`, or a literal.
If an image needs something those cannot express, that is a signal about the
Dockerfile, not a reason to grow the vocabulary.

## Validating locally (devbox)

Everything here runs on the devbox. Nothing needs a GPU except the runtime
behaviour the verify scripts deliberately do not test.

```sh
./scripts/build.sh check                 # the graph itself
./scripts/build.sh quasar-kde            # an image and its ancestors
./scripts/build.sh verify quasar-kde     # its verify scripts, from the graph
./scripts/build.sh all                   # everything, unigine included
./scripts/build.sh ci                    # exactly what GitHub Actions builds
```

`QUASAR_IMAGE_TAG` names the tag (default `dev`) and **every verify script
honours it**. It did not always: they hardcoded `:dev` while `build.sh` tagged
`$QUASAR_IMAGE_TAG`, so a verify could report a failure for a freshly built
image it never looked at — or, worse, report success. If you are comparing two
builds, give them different tags and trust the result.

Disk discipline on a shared box: `docker system df` before and after, and clean
up only what you created (your builders, your cache dirs, your dangling images).
Never `docker system prune` — local-only app image tags live there and are not
recoverable from any registry.

## The layer cache

Off by default. A bare `./scripts/build.sh` is the same
`DOCKER_BUILDKIT=1 docker build` it always was: a devbox already has a warm local
cache and gains nothing from an external one. CI is the opposite — every runner
is cold, which is the whole reason the knobs exist.

| variable | effect |
|---|---|
| `QUASAR_CACHE_REGISTRY=ghcr.io/accreleus` | import `<image>:buildcache` |
| `QUASAR_CACHE_DIR=/path` | import a local cache directory |
| `QUASAR_CACHE_WRITE=1` | export as well (`mode=max`) |
| `QUASAR_IMAGE_REGISTRY=…` | required by export — see below |
| `QUASAR_BUILDER=quasar-images` | buildx builder name |

Three facts that constrain the whole design, all learned the hard way:

1. **`--cache-to type=registry` is not supported by the default `docker`
   driver.** It fails the build; it does not degrade. Exporting cache means a
   `docker-container` buildx builder. Importing does not — which is why the
   pull-request path stays on the plain driver.
2. **A `docker-container` builder cannot resolve `FROM <local tag>`.**
   `FROM quasar-base:dev` inside one fails with `pull access denied …
   docker.io/library/quasar-base:dev` no matter how recently `--load` put that
   image in the local store. Every image here except `quasar-base` builds `FROM`
   a sibling, so the moment you export cache the siblings must be
   registry-resolvable. That is `QUASAR_IMAGE_REGISTRY`: each image is loaded
   locally *and* pushed there, and `graph.sh` resolves `@tag:` parents to the
   same ref. `build.sh` refuses export without it rather than failing inside
   BuildKit four minutes later.
3. **`--load` is not optional.** The container driver does not populate the local
   image store, so without it the build passes and the verify scripts then fail
   on `docker image inspect`.

`mode=max` (not `min`, not `inline`) because every expensive layer in this repo —
the Steam 32-bit closure, the bwrap and gamescope source builds, the kwin
rpmbuild — lives in a *discarded stage*, and only `mode=max` exports those.

Cache refs are **per image**. One shared ref would have each export overwrite the
previous image's manifest, leaving only the last image built with a usable cache:
caching that looks wired up and does nothing.

## The KWin artefact

`quasar-kde` does not ship Fedora's stock `kwin`; it rebuilds the distro source
package with `images/quasar-kde/kwin/*.patch`. That rebuild is **27 of the 35
minutes** of a full CI run, and it used to be paid by every run, including runs
that changed only a launcher script.

The RPMs are bit-identical whenever their inputs are, so they are an artefact:

- `FROM scratch AS kwin-rpms` carries the RPMs and nothing else (~12 MB pushed,
  rather than a 200 MB Fedora rootfs that happens to contain them).
- `scripts/kwin-artifact-tag.sh` is its content tag: a hash over `KWIN_NVR`,
  `KWIN_BUILDER_BASE`, every `kwin/*.patch` and every `kwin/build-kwin*.sh`.
  Nothing else invalidates it. It **refuses** to emit a tag if the builder base
  is not digest-pinned, because an unpinned base makes the tag a lie — `dnf
  builddep` resolves against whatever that base offers on the day.
- `KWIN_RPMS_IMAGE` selects the source. The default, `kwin-rpms`, resolves to the
  **local stage in the same Dockerfile**, so an ordinary local build is exactly
  what it always was. Point it at `ghcr.io/accreleus/quasar-kwin-rpms:<tag>`
  and BuildKit never instantiates the rpmbuild stages at all.

Inside the build the work is split across two stages so their cache keys cover
only what changes them:

- `kwin-deps` — fetch the pinned src.rpm, install ~1.5 GB of Qt/KF6 build
  dependencies. Keyed on `KWIN_BUILDER_BASE` + `KWIN_NVR` + `build-kwin-deps.sh`.
- `kwin-build` — apply the patches, `rpmbuild`. Keyed on those *plus* the
  patches.

Before the split the patches were copied in before `builddep` ran, so a one-line
patch edit re-bought the whole dependency install. Re-diffing is the recurring
cost this image is knowingly signed up for; it should not also cost that.

```sh
./scripts/kwin-artifact-tag.sh --explain   # what is hashed, and the tag
./scripts/build.sh quasar-kwin-rpms        # build the artefact on its own
KWIN_RPMS_IMAGE=ghcr.io/accreleus/quasar-kwin-rpms:<tag> \
  ./scripts/build.sh quasar-kde            # consume it
```

Re-diffing on a Fedora kwin update is in `README.md`, "Patched KWin (nested mode
ladder)". After a re-diff the tag moves on its own; publish the new artefact by
running the workflow on a branch that may write packages.

## The benchapp payload

`quasar-benchapp` lifts its binary out of another image whose source is the
separate, private `accreleus/quasar-mark` repo. `scripts/build.sh` resolves
which image:

1. `$BENCHAPP_SRC_IMAGE` — explicit override, always wins.
2. `quasar-benchapp:src` — a local build, if present. **The devbox loop**: build
   it in a quasar-mark checkout, then build here. Kept deliberately so iterating
   on the probe never has to go through a publish.
3. `ghcr.io/accreleus/quasar-benchapp-src:latest` — the clean-runner path.

**Operator prerequisite for (3):** that GHCR package is private by default.
Until it is made public, or granted **Read** access for the
`accreleus/quasar-images` repository (package → Package settings → *Manage
Actions access*), this repo's Actions token cannot pull it and the benchapp leg
of CI fails on the pull. No secret needs creating for that route.

## Pin policy

Every third-party input is pinned, and bumping a pin is the deliberate act that
says someone checked:

| pin | where | bumping means |
|---|---|---|
| Fedora base (image) | `images/quasar-base/Dockerfile`, digest | a new Fedora snapshot for the whole family |
| Fedora base (kwin builder) | `ARG KWIN_BUILDER_BASE`, digest | the RPMs compile against a different snapshot; the artefact tag moves |
| `ARG KWIN_NVR` | `images/quasar-kde/Dockerfile` | the patch was re-diffed against that source |
| `ARG BWRAP_REF` | `images/quasar-steam-runtime/Dockerfile` | a different bubblewrap; re-check `ignore-capabilities.patch` applies |
| gamescope `--branch` | `images/quasar-steam/Dockerfile` | a different gamescope; re-check the pointer-warp patch |
| UNIGINE URLs + sha256 | `images/quasar-unigine/Dockerfile` | a different benchmark build |
| `registry_ref` / `version` | `quasar-manifest.json` | a deliberate release to every syncing deployment |

A floating ref is a defect here even when it builds: it makes two boxes with
identical inputs produce different images, and it lets an upstream change reach
production with nothing bumped.

## What CI does, per event

`.github/workflows/image-build.yml` is the caller; `_build-images.yml` and
`_kwin-artifact.yml` hold the actual steps, so there is one definition of
build/verify/publish rather than the two verbatim copies there used to be.

| event | builds | cache | kwin artefact | publishes | token |
|---|---|---|---|---|---|
| `pull_request` → `stable` | the whole `ci` set | **read only** | reuse if present; a miss builds inline in quasar-kde | nothing | `contents: read`, `packages: read` |
| `push` → `stable` | the whole `ci` set | read + **write** | builds and publishes on a miss | `:latest` + `sha-<12>` | `packages: write` |
| `push` tag `vX.Y.Z` | the whole `ci` set | read + write | as above | `:X.Y.Z`, `:X.Y`, `:latest`, `sha-` + a GitHub Release | `packages: write`; release job alone gets `contents: write` |
| `workflow_dispatch` | the whole `ci` set | read + write | as above | that branch's channel (`develop` → `:develop`) | `packages: write` |
| `push` → `develop` | *no workflow runs* | — | — | — | — |

**The security model.** A `pull_request` run executes `scripts/*.sh` and the
Dockerfiles **from the PR**, so it must hold nothing it could abuse. Every job
therefore exists twice — a `-pr` variant with `packages: read` and a `-publish`
variant with `packages: write` — selected by a static `if:` on the event.

That duplication is deliberate: `permissions:` does not accept expressions, so a
single job cannot vary its token by event, and the alternative is one job holding
`packages: write` on pull requests. `packages: write` is **not scoped to one
package** — a PR that edited a build script could push over
`quasar-base:latest`. What is shared is the work, not the credentials.

The same reasoning is why the kwin artefact job does not build on a pull request:
given write, a PR could rewrite `build-kwin.sh` and publish arbitrary content
under the org's namespace. A PR that changes a kwin input pays the 27 minutes
inline instead, which is the right outcome — it is proving that build still
works.

Cache **write** is likewise publish-only: a pull request must never be able to
poison what `stable` later builds from.

`stage/*` packages (`ghcr.io/accreleus/stage/quasar-base`, …) are build
scaffolding written by publishing runs to satisfy constraint (2) above — the
intermediate images a container builder has to resolve `FROM` against. Nothing
outside a run consumes them; they are a separate namespace so that is obvious.

## Cross-image gotchas from investigation records

Not every dead end gets its own image. `docs/specs/2026-08-15-quasar-gnome-blocked.md`
is a decision record (quasar-gnome will not ship on Fedora 43 — mutter's only
nested backend is compiled out when x11 support is off), but two of its findings
are load-bearing for every other image in this repo, not just GNOME:

- **The login1 blocker.** Any Wayland session in this family that talks to
  `org.freedesktop.login1` (gnome-shell did) hard-fails while
  `/run/systemd/seats` exists — and it exists in our base image, shipped by the
  systemd RPM. `rmdir /run/systemd/seats` is the fix if a future session hits it.
- **`waylandsink` rejects an absolute `WAYLAND_DISPLAY`.** It needs
  `XDG_RUNTIME_DIR` plus a relative socket name — the exact opposite of the
  absolute-path convention `quasar-kde`, `quasar-steam`, `quasar-benchapp`, and
  `quasar-unigine` all resolve to first (see each launcher's `WAYLAND_DISPLAY`
  handling). Anyone wiring a GStreamer sink directly against the parent
  compositor socket will lose time to this if they don't know it going in.

## Devices and the uid/gid drop

`quasar-entrypoint` drops to the application user with `setpriv --reuid --regid
--init-groups`, and **`--init-groups` rebuilds the supplementary group set from
`/etc/group`** (initgroups(3)). Every gid the host granted the container —
`docker run --group-add <gid>`, which is how the node-agent passes the host's
`render`/`video` gids alongside `--device /dev/dri` — is therefore **discarded at
the drop**. The container's root process could open the device; the application
cannot.

That is not a hypothetical either: it shipped. `quasar-steam` on an AMD host
with 0660 DRM nodes enumerated only `llvmpipe` as uid 1000, so gamescope aborted
on the missing `VK_EXT_physical_device_drm` and the app exited 1 — while the
container's own GPU contract check reported `"result":"pass"`, because it ran
pre-drop as root and root holds `CAP_DAC_OVERRIDE`.

Two rules follow, and both are now mechanism rather than advice:

1. **A device the app must open needs the app user to be a MEMBER of its owning
   group before the drop** — `overlay/etc/quasar/init.d/10-dri-device-groups.sh`
   does that for `/dev/dri/*` (groupadd by gid when the host's gid has no name
   in the container, then `usermod -aG`). Membership, not
   `setpriv --keep-groups`: it keeps the drop's semantics for everything else,
   and `id` inside the container then names what it has. **gid 0 is never
   granted** — a 0660 root:root node is a misconfigured host and stays broken
   and logged.
2. **Anything that checks what the application can do must run post-drop.** The
   GPU probe now runs under the same `setpriv` as the command does. A check that
   runs as root cannot fail the way a session fails, and one that cannot fail
   reads as cover.

The other device path in this family, `15-input-device-perms.sh`, solves the
same class of problem the other way (it opens gamepad nodes to 0666) because
those nodes are created root-owned inside the container and have no meaningful
host group to join.

## Verify scripts

`scripts/verify*.sh` are structural, not functional: they assert labels,
entrypoints, launcher wiring, package markers, and a few genuinely runnable
smokes (the KDE one starts a nested `kwin_wayland` and changes resolution and
scale). They do not need a GPU.

Which ones run is `build-graph.json`'s `verify` field, so a wired script is a
script that runs. `verify-benchapp.sh` and `verify-unigine.sh` sat unrun for
months because nothing referenced them; wiring is now a data edit. One script is
deliberately *not* wired: `scripts/validate-steam-runtime.sh` prints Steam
launcher behaviour for a human to read rather than asserting anything, so it is a
manual tool, not a gate. Run it by hand after touching the launcher.

**The caller builds; the verify checks.** `build.sh verify <image>` has already
built the image, and sets `QUASAR_VERIFY_ASSUME_BUILT=1` so the verify does not
build it again. A verify that rebuilds is a verify that can quietly repair a
stale image instead of failing on it. Standalone (`./scripts/verify-kde.sh`) it
still builds; `--no-build` skips that.

### Writing an assertion

Source `scripts/lib/verify-lib.sh` and call `qv_init`. Two rules, both paid for:

1. **An assertion must say what it checked.** A bare `grep -q` under `set -e`
   exits 1 having printed nothing at all. That is what stalled the stable
   promotion on 2026-08-25: `verify-kde.sh` asserted a `FROM fedora:43 AS
   kwin-build` line that a legitimate refactor had removed, and the whole script
   died in silence after 2.1 seconds. Use `assert_grep` / `assert_file` /
   `assert_exec` with a `why`, and prefix in-image `docker run` bodies with
   `"$QV_GUARD"` so a failure inside the container reports its line too. `qv_init`
   installs an ERR trap, so even an assertion written the old way now names
   itself.
2. **Never write `! cmd`.** bash does not apply `set -e` to a `!`-inverted
   command, so `! grep -q setsid "$launcher"` can *never* fail — it reads as a
   guard and is a no-op. Seven such lines were live in this repo, including both
   of `verify-benchapp.sh`'s fail-closed checks. Use `refute_grep`,
   `refute_grep_text`, `refute_cmd`, `qv_image_lacks`, or an explicit
   `if ...; then echo FAIL >&2; exit 1; fi`.

Prefer asserting *structure* over an exact line, and never restate a rule another
script owns — `verify-kde.sh` calls `kwin-artifact-tag.sh` for the digest-pin
check rather than re-grepping for it, because restating it is how the previous
assertion drifted.
