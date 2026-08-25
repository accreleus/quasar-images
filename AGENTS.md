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
   ordering, a `ci: true` image on a `ci: false` parent, and verify scripts.
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
| `QUASAR_CACHE_REGISTRY=ghcr.io/accretion-io` | import `<image>:buildcache` |
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
  what it always was. Point it at `ghcr.io/accretion-io/quasar-kwin-rpms:<tag>`
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
KWIN_RPMS_IMAGE=ghcr.io/accretion-io/quasar-kwin-rpms:<tag> \
  ./scripts/build.sh quasar-kde            # consume it
```

Re-diffing on a Fedora kwin update is in `README.md`, "Patched KWin (nested mode
ladder)". After a re-diff the tag moves on its own; publish the new artefact by
running the workflow on a branch that may write packages.

## The benchapp payload

`quasar-benchapp` lifts its binary out of another image whose source is the
separate, private `accretion-io/quasar-mark` repo. `scripts/build.sh` resolves
which image:

1. `$BENCHAPP_SRC_IMAGE` — explicit override, always wins.
2. `quasar-benchapp:src` — a local build, if present. **The devbox loop**: build
   it in a quasar-mark checkout, then build here. Kept deliberately so iterating
   on the probe never has to go through a publish.
3. `ghcr.io/accretion-io/quasar-benchapp-src:latest` — the clean-runner path.

**Operator prerequisite for (3):** that GHCR package is private by default.
Until it is made public, or granted **Read** access for the
`accretion-io/quasar-images` repository (package → Package settings → *Manage
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

`stage/*` packages (`ghcr.io/accretion-io/stage/quasar-base`, …) are build
scaffolding written by publishing runs to satisfy constraint (2) above — the
intermediate images a container builder has to resolve `FROM` against. Nothing
outside a run consumes them; they are a separate namespace so that is obvious.

## Verify scripts

`scripts/verify*.sh` are structural, not functional: they assert labels,
entrypoints, launcher wiring, package markers, and a few genuinely runnable
smokes (the KDE one starts a nested `kwin_wayland` and changes resolution and
scale). They do not need a GPU.

Which ones run is `build-graph.json`'s `verify` field, so a script that exists is
a script that runs. `verify-benchapp.sh` and `verify-unigine.sh` sat unrun for
months because nothing referenced them; wiring is now a data edit.
