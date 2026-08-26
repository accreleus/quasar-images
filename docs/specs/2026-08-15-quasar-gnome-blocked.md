# Decision record: quasar-gnome blocked on Fedora 43

Date: 2026-08-15
Status: decided — **do not ship `quasar-gnome` on Fedora 43** (user decision,
2026-08-15). This document is the deliverable; no Dockerfile or image exists
for `quasar-gnome` and none is planned unless §3's revisit trigger fires.
Scope: this repository. Companion to
`docs/specs/2026-08-13-quasar-kde-implementation.md`, whose conventions the
abandoned implementation was following.

## 1. Finding

**`gnome-shell` cannot be run as a nested Wayland client of a parent compositor
using stock Fedora 43 packages.** The quasar-kde architecture (nested `kwin`
consuming the node-agent's compositor socket) has no GNOME equivalent here.

All evidence below was produced live on the dev box against
`quasar-steam-runtime:dev` plus the GNOME 49 package set
(gnome-shell-49.9, mutter-49.7, gnome-session-49.3, gnome-software-49.4), with a
virtual parent compositor:
`mutter --headless --virtual-monitor 1920x1080 --wayland-display wayland-parent`.

1. **`gnome-session` is systemd-user-only in 49.** No `--builtin` and no
   equivalent; the whole option set is `--session/--debug/--version/--no-reexec`.
   Under `dbus-run-session` it dies:
   `ERROR: Failed to start unit gnome-session-wayland@gnome.target:
   GDBus.Error:org.freedesktop.DBus.Error.NameHasNoOwner: Name
   "org.freedesktop.systemd1" does not exist`.
   (It also hard-requires `XDG_SESSION_TYPE`: `ERROR: XDG_SESSION_TYPE= is unset!`)

2. **`gnome-shell --wayland` without `--display-server` does NOT go nested.** It
   takes the *native* backend and dies on logind:
   `Failed to setup: Failed to find any matching session`. Identical result with
   `DISPLAY=:0` set and with the parent socket exported as `WAYLAND_DISPLAY`.

3. **`--nested` is not a recognised option.**
   `gnome-shell --wayland --nested` → `Failed to configure: Unknown option
   --nested`; same for `mutter --nested`. The option long-name does not appear in
   `libmutter-17.so.0`'s strings at all, and there is no `--x11` option either.
   `--help-all` for both binaries lists only: `--wayland --no-x11
   --wayland-display --display-server --headless --virtual-monitor --devkit
   --profile --debug-control --version` (+ `--mode/--list-modes/--force-animations`
   for gnome-shell, `--mutter-plugin` for mutter).

4. **Upstream source explains it.** In mutter 49.1 `src/core/meta-context-main.c`,
   both the option entry and the backend are guarded:

   ```c
   #ifdef HAVE_WAYLAND
   #ifdef HAVE_X11
       { "nested", 0, 0, G_OPTION_ARG_NONE, &context_main->options.nested, ... },
   #endif
   #endif
   ```
   ```c
   #if defined (HAVE_X11) && defined (HAVE_WAYLAND)
   static MetaBackend *
   create_nested_backend (MetaContext *context, GError **error)
   {
     return g_initable_new (META_TYPE_BACKEND_X11_NESTED, ...);
   }
   #endif
   ```

   Fedora 43 builds mutter with x11 support **off** (the GNOME 49 X11-session
   removal; Xwayland is a separate build switch and stays on). So mutter's only
   nested backend is compiled out — and it was X11-based regardless, which a
   Wayland-only parent could not host directly.

5. **Upstream's replacement is `--devkit`, and it presents nothing on its own.**
   `--devkit` selects the *headless* backend and spawns
   `/usr/libexec/mutter-devkit`, which ships only in `mutter-devel`. With that
   binary absent, `gnome-shell --wayland --devkit` runs — shell alive, its own
   `Xwayland :2`, notifications daemon, calendar server — but
   `org.gnome.Mutter.DisplayConfig.GetCurrentState` reports **zero monitors** and
   a `WAYLAND_DEBUG=1` trace of the parent connection shows **zero
   `wl_surface.attach`**. Nothing is ever presented.

## 2. Options considered, and what was actually proved

### A — rebuild libmutter with `-Dx11=true`

Restores `--nested`. The runtime stack would be
parent ← rootful Xwayland ← mutter X11-nested ← gnome-shell.

**Substrate proved viable.** `Xwayland :5 -geometry 1920x1080` is a well-behaved
client of a Wayland parent:

```
-> xdg_surface#15.get_toplevel(new id xdg_toplevel#16)
-> xdg_toplevel#16.set_title("Xwayland on :5")
   xdg_toplevel#16.configure(1920, 1080, array[4])
-> wl_surface#14.attach(wl_buffer#13, 0, 0)
```

Real input, no capture hop. Cost: an out-of-distro libmutter that must stay
ABI-matched to gnome-shell (`libmutter-17`), plus a heavy builder stage, on every
rebuild. Not proved end-to-end — the mutter rebuild was never attempted.

### B — devkit / `mutter-devkit` (mdk)

The only upstream client that does **both** presentation and input: it drives
`org.gnome.Mutter.RemoteDesktop` for input and PipeWire for video. It did not
complete here, failing on its prerequisites:

```
mdk-WARNING: Failed to initialize launch environment: No launch environment available
mdk-WARNING: Context got an error: Cannot invoke method; proxy is for the well-known
             name org.gnome.Mutter.RemoteDesktop without an owner
```

`mutter-devel` is +530MB installed (the binary itself is 204KB and extractable).
A development kit in a product image, with a screen-capture round trip.

### C — headless shell + our own presenter — video YES, input NO

Fully proved for video, with no source builds and only +60MB of packages
(`pipewire pipewire-gstreamer wireplumber gstreamer1-plugins-bad-free`):

```
gnome-shell --wayland --headless --virtual-monitor 1920x1080   -> ALIVE
DisplayConfig: ('Meta-0', 'MetaVendor', 'MetaVirtualMonitor'), 1920x1080@60.000
ScreenCast: CreateSession -> RecordMonitor("Meta-0") -> Start -> NODEID=44
gst-launch-1.0 pipewiresrc path=44 ! videoconvert ! waylandsink
  -> Pipeline is PREROLLED / Setting pipeline to PLAYING   (toplevel on the parent)
```

**Dead on input.** `waylandsink` is a video sink; it never forwards pointer or
keyboard events into the session. Making C usable means feeding
`org.gnome.Mutter.RemoteDesktop` (`NotifyPointerMotionAbsolute`,
`NotifyKeyboardKeycode`) from the sink window's Wayland events — i.e. writing and
owning a remote-desktop client. That is an application, not glue.

### D — do not ship quasar-gnome on Fedora 43 — **CHOSEN**

C is out. B is a dev tool with a capture hop. A is a large, permanent build
surface for a two-layer stack. None of them is worth a GNOME desktop that is
architecturally worse than the KDE one we already ship.

## 3. Revisit trigger

Reopen this when **either** holds:

- mutter gains a **Wayland**-nested backend (i.e. nesting stops being tied to
  `HAVE_X11`), or the devkit path stops requiring `mutter-devel` and gains a
  supported non-development mode; **or**
- the image base moves to a distro/release whose mutter is still built with
  `-Dx11=true`, which restores `--nested` (option A without the rebuild).

The check is cheap and should be the first thing run on any revisit:
`gnome-shell --wayland --nested --version` — if that is not
`Unknown option --nested`, the architecture is available again.

## 4. Settled anyway (reusable if we revisit)

Everything below was established during the investigation and is independent of
the launch path. `80ef529` on `feat/gnome-image` carries the first two items as
real files.

- **gschema overrides** —
  `images/quasar-gnome/overlay/usr/share/glib-2.0/schemas/95-quasar-gnome.gschema.override`.
  Neutralises lock/idle/suspend, the shell welcome dialog, gnome-software's
  first-run + background downloads, localsearch indexing, and external search
  providers. Every key was checked with `gsettings range` and the file was
  compile-tested with `glib-compile-schemas` in the real image
  (`glib-compile-schemas` hard-fails on an override for a non-existent key, so
  this is a build gate rather than a silent no-op).
- **Branding** — `quasar.svg` + 256px `quasar.png` at the hicolor paths, copied
  from quasar-kde. GNOME has no start button, so the icon is the whole of it.
- **The login1 fix (applies to every path).** gnome-shell 49 hard-fails at
  startup whenever `/run/systemd/seats` exists — and it does exist in our base
  image, shipped by the systemd RPM:

  ```
  GNOME Shell-WARNING: Failed to start state machine: Error calling
    StartServiceByName for org.freedesktop.login1: Launch helper exited ...
  Gjs-CRITICAL: JS ERROR: Gio.DBusError: ... org.freedesktop.login1 ...
    LoginManagerSystemd@resource:///org/gnome/shell/misc/loginManager.js:98:23
  ```

  `rmdir /run/systemd/seats` in the Dockerfile flips libshell to
  `LoginManagerDummy`. Verified: shell DEAD → ALIVE.
- **Package facts (Fedora 43).** `tracker-miners` is renamed **`localsearch`**,
  and it arrives as a hard dependency of nautilus (neutered via schema, not
  force-removed). **`gdm` is unavoidable**: it Provides `gdm-libs(x86-64)`, which
  gnome-shell Requires — 5.5MB that never runs. `evolution-data-server` and
  `gnome-online-accounts` arrive via langpacks/deps.
  Terminal: **ptyxis** (Fedora 43 default, 2.0MB) over gnome-terminal.
  Store: plain **`gnome-software`** — the Flatpak backend is built in
  (`libgs_plugin_flatpak.so` is present); no split package exists.
  `/usr/share/applications/steam.desktop` is inherited from quasar-steam-runtime.
- **File capabilities.** The only one in the image is
  `/usr/libexec/gstreamer-1.0/gst-ptp-helper
  cap_net_bind_service,cap_net_admin,cap_sys_nice=ep`, and it is **inherited from
  quasar-steam-runtime** (present there too). No GNOME session binary carries a
  file cap, so no `setcap -r` would be needed for this image — unlike quasar-kde,
  where `kwin_wayland`'s `cap_sys_nice=ep` makes execve fail EPERM.
- **Nested sizing mechanism.** `--virtual-monitor WxH[@R]` on both `gnome-shell`
  and `mutter`. `MUTTER_DEBUG_DUMMY_MODE_SPECS` no longer exists (it is absent
  from libmutter 49's `MUTTER_*` env strings). Note that `--virtual-monitor`
  forces the native/headless backend.
- **Two gotchas that cost real time.** A Mutter ScreenCast session is destroyed
  when the D-Bus connection that created it drops, so a sequence of separate
  `gdbus call` invocations can never work — the session needs one process holding
  the connection open. And GStreamer's `waylandsink` cannot use an **absolute**
  `WAYLAND_DISPLAY` (`Failed to connect to the wayland display '(default)'`); it
  needs `XDG_RUNTIME_DIR` plus a relative socket name — the exact opposite of the
  absolute-path contract the quasar-kde launcher relies on.

## 5. Not done

No Dockerfile, launcher, `scripts/verify-gnome.sh`, `scripts/build.sh` wiring,
nested smoke, or live luma run. No `quasar-gnome` image was ever built, so there
is no size delta to report. The CI workflow, README and manifest were not
touched.
