# quasar-kde: implementation specification — KDE Plasma desktop with Steam

Date: 2026-08-13
Status: reviewed — open items resolved §6; awaiting user go for implementation
(supersedes parts of `2026-07-25-quasar-kde-design.md`)
Scope: this repository only. Agent-side work (volume mounting, seccomp profile,
session policy) is documented as host requirements, not implemented here.

## Relationship to the 2026-07-25 design spec

The original design spec settled: FROM quasar-app, user-level Flatpak, single
`$HOME` volume persistence, light branding, Plasma 6 Wayland-only, baked
`/etc/xdg` defaults, agent-provided game menu entries.

**One decision is reversed by explicit user direction (2026-08-13): the Steam
desktop client IS included in the image.** The original "games via Quasar
session-switch only" model becomes additive — agent menu entries still work if
mounted, but the desktop also carries a full Steam client for desktop-mode use.

Everything else from the design spec stands.

## 1. Steam desktop client in the KDE image

**Mode statement (settled 2026-08-13): quasar-kde ships the Steam DESKTOP
client, not Big Picture.** BPM vs desktop is purely launch-time flags on the
same RPM: the quasar-steam image's launcher runs `steam -bigpicture` inside
gamescope; quasar-kde's menu entry runs plain `steam` — the normal windowed
desktop client. Nothing BPM-flavoured is wired in quasar-kde (a user can still
enter Big Picture from Steam's own View menu, as on any desktop Linux).

### Layering decision: shared `quasar-steam-runtime` layer

Adding Steam to a quasar-app-based image would duplicate the entire validated
Steam stack: RPM Fusion repos, the `steam` package, the 32-bit graphics
userspace, and critically the **patched non-setuid bwrap** (pressure-vessel
rejects a bwrap binary carrying capabilities in any UI mode). Inheriting all
of quasar-steam instead would drag in the BPM-only pieces (patched gamescope,
BPM launcher). The clean cut — chosen after review discussion — is a new
intermediate image holding exactly the mode-neutral Steam runtime:

```
quasar-base -> quasar-app -> quasar-steam-runtime -> quasar-steam  (+ patched gamescope, BPM launcher)
                                                  -> quasar-kde    (+ Plasma desktop)
```

`images/quasar-steam-runtime/` contains, moved verbatim from today's
quasar-steam Dockerfile:

- RPM Fusion repos + `steam` + 32-bit GL/Vulkan userspace + `dbus-daemon`,
  `NetworkManager`, `ibus`, supporting tools
- The `bwrap-builder` stage + patched bwrap install
- `20-steam-system-services.sh` init hook + NM conf (the desktop Steam client
  has the same libnm dependency as Big Picture — quasar-images#4)

`images/quasar-steam/` retains: the `gamescope-builder` stage + patched
gamescope, the `quasar-steam`/`quasar-steam-client` launchers,
`ENV QUASAR_STEAM_GAMESCOPE=1`, and its CMD. Its final stage becomes
`FROM ${STEAM_RUNTIME_IMAGE}`. Net content of the published quasar-steam image
is unchanged — same packages, same files — but layer digests change, so one
regression QA pass on the Steam image is part of acceptance.

quasar-kde carries zero gamescope/BPM weight.

### How Steam launches under the KDE session

Steam desktop mode is a plain X11 application. `kwin_wayland` is started with
`--xwayland`, so Xwayland is present for the whole session; Steam's stock
`.desktop` entry (`/usr/share/applications/steam.desktop`, shipped by the RPM)
appears in the Kickoff menu automatically. No wrapper script: the user clicks
Steam in the menu, it runs windowed under KDE like any desktop Linux install.
Games launched from it run under the same session (Proton via pressure-vessel
uses the patched bwrap).

No autostart of Steam. The desktop boots to an empty desktop; Steam is
menu-launched.

### Security consequences (carried from the security discussion)

- **`no_new_privileges` MUST be `false`** for quasar-kde, same as quasar-steam
  and for the same reason (Steam's startup re-escalation). The earlier plan to
  keep desktop images NNP-true dies with the decision to include Steam.
- **Unprivileged user namespaces required** (user-level Flatpak's bwrap and
  pressure-vessel). Host requirement: the agent runs this image with a seccomp
  profile permitting `clone(CLONE_NEWUSER)`. Documented in the image README;
  the GOW-style setuid-bwrap/sudoers approach is explicitly rejected.
- No sudo rules, no setuid binaries added by this image.

## 2. Quasar logo as the application-launcher (Kickoff) icon

**Feasible — confirmed.** This is standard distro customization (SteamOS and
Bazzite both do it). Two baked pieces:

1. **Icon asset:** `/usr/share/icons/hicolor/scalable/apps/quasar.svg` (plus
   256px PNG fallback at `icons/hicolor/256x256/apps/quasar.png`).
2. **Kickoff default icon** *(path corrected during unit 1 — the design-spec's
   assumed `plasma/shells/.../layout.js` does not exist on Plasma 6.7.4 /
   Fedora 43; verified empirically on the dev box)*: override Fedora's
   plasmoid-setup script
   `/usr/share/plasma/look-and-feel/org.fedoraproject.fedora.desktop/contents/plasmoidsetupscripts/org.kde.plasma.kickoff.js`,
   which is what actually runs on Kickoff-applet creation, so a fresh applet
   gets `icon = "quasar"`. Applies on first run (no
   `plasma-org.kde.plasma.desktop-appletsrc` in `$HOME` yet); a user who
   changes the icon keeps their change — per-user config wins.

Fragility note: the file is replaced wholesale, so a Plasma/kde-settings bump
can drift from upstream. Mitigation: the verify script asserts the file still
contains the `writeConfig("icon", "quasar")` assignment, so a silent
regression fails CI rather than shipping.

**Logo asset (provided 2026-08-13):** the Quasar mark from the site build —
`/Users/michael/code/quasar/site/dist/_astro/quasar-mark.DOqKpC47.svg`
(571 B, 32x32 viewBox, gradient mark). Copied into this repo as
`images/quasar-kde/overlay/usr/share/icons/hicolor/scalable/apps/quasar.svg`
(committed here so image builds never depend on a sibling repo's dist output);
a 256px PNG raster is generated from it at build/commit time for the hicolor
fallback.

## 3. Image composition

New directory `images/quasar-kde/`:

```
images/quasar-kde/
  Dockerfile
  quasar-kde                       # session launcher (CMD)
  overlay/etc/xdg/                 # baked Plasma defaults (kscreenlockerrc, powerdevil, baloofilerc, kwalletrc)
  overlay/usr/share/icons/hicolor/scalable/apps/quasar.svg
  overlay/usr/share/plasma/.../layout.js
```

### Dockerfile

- `ARG STEAM_RUNTIME_IMAGE=quasar-steam-runtime:dev` / `FROM ${STEAM_RUNTIME_IMAGE}`
  + `ARG VERSION`.
- Contract labels: standard set (contract=1, family=fedora, acceleration=required,
  graphics-apis, entrypoint) **plus** `org.quasar.image.persist="/home/quasar"`
  and `org.quasar.image.session="desktop"` (from the design spec).
- Packages (weak deps off, cache cleaned in-layer):
  - Session: `plasma-desktop plasma-workspace-wayland kwin`
    (dbus-daemon already inherited)
  - Portal: `xdg-desktop-portal-kde`
  - Apps: `konsole dolphin`
  - Flatpak: `flatpak plasma-discover plasma-discover-flatpak`
  - Fonts: `google-noto-sans-fonts google-noto-emoji-fonts google-noto-sans-mono-fonts`
- Excluded (design-spec list): SDDM, NM applet, akonadi/PIM, kwallet
  integration, baloo (disabled via config), Discover rpm/ostree backends.
- **Lean-image principle (user directive 2026-08-13): strip anything unneeded.**
  Weak deps stay off everywhere; no recommended-package drift; dnf cache
  cleaned in-layer; no docs/locales beyond en (`--setopt=tsflags=nodocs` +
  glibc-langpack-en only, matching base); anything pulled in that the session
  does not use gets an explicit removal or exclusion. Applies to unit 0 too:
  the steam-runtime split must not grow the combined footprint, and the KDE
  image carries zero gamescope/BPM weight by construction. Image size is
  reported per unit so growth is a reviewed fact, not a surprise.
- Container-pruning lessons from GOW, KDE equivalents: no screen locker
  autostart, polkit agent suppressed if it misbehaves without logind
  (verified during QA on the dev box, not assumed).
- CMD `/usr/local/bin/quasar-kde`.

### Session launcher `images/quasar-kde/quasar-kde`

Mirrors `quasar-steam`'s structure (same conventions, no setsid/setpgid/group
kills — verify script enforces):

1. Wayland socket handoff: resolve `WAYLAND_DISPLAY` to an absolute path, then
   repoint `XDG_RUNTIME_DIR` to a private user-owned dir (verbatim pattern from
   quasar-steam lines 13–17).
2. First-run `$HOME` init (idempotent, marker-guarded):
   `xdg-user-dirs-update`; `flatpak remote-add --user --if-not-exists flathub`
   (failure = warning, not fatal — desktop must start offline).
3. Resolution: `QUASAR_STREAM_WIDTH/HEIGHT/FPS` → fall back 1920x1080x60 —
   same precedence contract as quasar-steam (quasar#384: nothing baked as ENV).
   Applied via `kwin_wayland --width W --height H` on the nested output.
4. Game-menu mount: append `/run/quasar/share` to `XDG_DATA_DIRS` when the
   directory exists (agent-provided `.desktop` entries; absent = no games
   section, no error).
5. Launch: `dbus-run-session -- startplasma-wayland` with kwin nested against
   the parent compositor socket. Exact invocation (whether `startplasma-wayland`
   respects size flags or kwin needs wrapping) is settled empirically on the
   dev box — acceptance criterion below, not guessed here.
6. Shutdown: trap TERM/INT, relay a single TERM to the session leader, bounded
   wait (`QUASAR_KDE_SHUTDOWN_TIMEOUT`, default 8s), same launcher-owned relay
   contract as quasar-steam. No group kills.

## 4. Build/CI changes (ordered implementation steps)

Each step is a commit unit: green, committed, then next.

0. **Steam-runtime split (refactor, no content change)** — extract
   `images/quasar-steam-runtime/` from quasar-steam per §1; quasar-steam's
   final stage rebased onto it; `build.sh` gains `build_steam_runtime` in the
   chain. Green = `./scripts/build.sh quasar-steam` + `verify-steam.sh` pass on
   the dev box AND QA regression pass on the Steam image (input +
   `docker stop` clean-shutdown + BPM reaches sign-in). The runtime image is a
   local build stage like quasar-base/app — published to the registry alongside
   the others only if the workflow's per-image loop makes that simpler;
   otherwise it stays unpublished (nothing consumes it directly).
1. **Scaffold image** — `images/quasar-kde/Dockerfile` + overlay defaults +
   placeholder branding + `build.sh` entry
   (`quasar-kde) build_base; build_app; build_steam_runtime; build_kde ;;` +
   `all`). Green = image builds on the dev box.
2. **Session launcher** — `images/quasar-kde/quasar-kde` per §3. Green =
   structural checks pass + session starts against a compositor on the dev box.
3. **Verify script** — `scripts/verify-kde.sh` (pattern of `verify-steam.sh`):
   binaries present (`startplasma-wayland`, `kwin_wayland`, `flatpak`,
   `dbus-run-session`, `steam`, `bwrap`), baked defaults present, launcher
   negative assertions (no setsid/setpgid/group-kill — explicit if/exit form,
   not `! grep`), layout.js Kickoff icon assertion, labels assertion including
   `persist` + `session`. Green = passes locally against a dev-box-built image.
4. **CI wiring** — add `quasar-kde` to the workflow publish loop and
   `verify-kde.sh` to validate+publish jobs. README hierarchy update.
5. **Manifest entry** — `quasar-manifest.json`: id `kde-desktop`, kind
   prebuilt, CalVer version + pinned digest (only after a published build),
   `runtime`: `gpu: true`, `no_new_privileges: false` (documented in notes),
   `managed_home: true`, `home_container_path: /home/quasar`,
   `network: "bridge"` (Steam needs it, same as the steam image). This is a
   contract-surface change — reviewed separately.

Builds: **Quasar Dev Box only** (repo rule: never the Mac). Check docker disk
space before builds; prune artifacts after.

## 5. Acceptance criteria

**A. Image builds and structure**
- `./scripts/build.sh quasar-kde` succeeds on the dev box.
- `./scripts/verify-kde.sh` passes: all binaries, defaults, labels, launcher
  invariants.
- Steam-runtime split regression (unit 0): `verify-steam.sh` green AND QA
  confirms the rebuilt quasar-steam image unchanged in behaviour (input works,
  clean `docker stop`, BPM reaches sign-in).

**B. Session**
- Container started under Quasar (or with a hand-provided parent Wayland
  socket) reaches a rendered Plasma desktop; keyboard + mouse work.
- Relaunch with a populated `$HOME` volume preserves config/apps (persistence
  check: seed, relaunch, assert intact).
- `docker stop` yields a clean session exit within the timeout budget (no
  SIGKILL backstop needed in the normal case).

**C. Steam desktop client**
- Steam appears in the Kickoff menu; launching it from the menu reaches the
  Steam login/storefront window under the KDE session.
- With a signed-in account: a small game installs and launches windowed under
  KDE (pressure-vessel/bwrap path exercised).

**D. Branding / launcher icon**
- Fresh `$HOME`: Kickoff shows the Quasar icon (placeholder until real asset).
- User-changed icon survives relaunch (per-user config wins).

**E. Flatpak**
- First run adds the Flathub user remote; `flatpak install --user` of a small
  app succeeds and the app launches (userns/seccomp host requirement proven).
- Discover opens and shows Flathub content.

**F. Contract/manifest**
- Labels include `persist=/home/quasar`, `session=desktop`.
- Manifest entry validates against MANIFEST.md rules (pinned digest, CalVer,
  NNP-false documented in notes).

QA (Phase 3) tests B–E on real hardware via the Quasar QA role; A and F are
CI/self-verifiable. Each unit ships to QA with its criteria listed; only QA
sign-off closes B–E.

## 6. Resolved review items (2026-08-13)

1. **Logo asset**: provided — site Quasar mark (see §2); committed into this
   repo, PNG fallback generated.
2. **Lean images**: standing directive — strip anything unneeded; size
   reported per unit (see §3).
3. **Manifest id**: `kde-desktop` approved. `library_provider` deliberately
   absent (this is not the canonical Steam provider image — `steam` id stays
   that).
4. **QA contact**: message the thread "Quasar QA testing role" for every
   Phase 3 hand-off (unit + acceptance criteria), and again for each
   fix-retest cycle; only that thread's sign-off closes units B–E and the
   unit-0 Steam regression.
