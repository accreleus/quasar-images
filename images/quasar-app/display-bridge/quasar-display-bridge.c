/*
 * quasar-display-bridge: the display-mode bridge between a rootful Xwayland and the Quasar
 * compositor it runs on (quasar #445).
 *
 * Why it exists. Any X11 desktop here runs on a rootful Xwayland, and a rootful Xwayland
 * ignores the compositor's wl_output mode list entirely (hw/xwayland/xwayland-output.c,
 * xwl_screen_init_randr_fixed): it builds its own RandR mode table, every entry at a
 * hard-coded 60 Hz, and a RandR mode change only resizes its own window. So the desktop's
 * display settings could never list the monitor's real modes, and a choice never reached the
 * compositor. Wayland has no client request for a mode change; the protocol for it is
 * wlr-output-management-unstable-v1, which the Quasar compositor implements (one head, the
 * monitor's modes, each with its own refresh).
 *
 * What it does. Two connections: wl (the parent compositor, as a wlr-output-management
 * client) and X (the Xwayland this desktop runs on, as a RandR client).
 *   1. On every wlr `done`, mirror the head's modes into RandR as user modes on the
 *      XWAYLAND0 output (XRRCreateMode + XRRAddOutputMode), skipping a mode Xwayland already
 *      lists at the same size and whole-hertz rate, and dropping user modes the compositor
 *      no longer advertises. The desktop's display settings then list them, with their refresh.
 *   2. On every RandR CRTC change (the user applied a mode), find the compositor mode of
 *      that size with the nearest refresh and apply it through wlr-output-management.
 *      Xwayland has already resized its own window to the new size; the compositor letterboxes
 *      until the agent moves the display and re-pins the compositor at the new mode, at which
 *      point Xwayland follows the configure and the screen is 1:1 again.
 *   3. When the compositor's current mode changes without a RandR change (the agent moved
 *      it, or the choice came from elsewhere), nothing to do: Xwayland follows the
 *      configure on its own.
 *
 * Refresh is the whole reason this is not just `xrandr`: Xwayland's own modes are all
 * 60 Hz, so the refresh a user picks exists only in the modes this bridge adds, and the
 * RandR notification carries it back here as the mode's dot clock / totals.
 *
 * Privilege: none. A plain X11 client of :0 and a plain Wayland client of the parent
 * socket; no caps, no devices. It exits when either connection closes.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>
#include <wayland-client.h>

#include "wlr-output-management-unstable-v1-client-protocol.h"

#define MAX_MODES 128

struct wlr_mode {
    struct zwlr_output_mode_v1 *proxy;
    int32_t width, height, refresh_mhz;
    bool preferred, finished;
    /* The RandR user mode this bridge created for it (0 = none, e.g. Xwayland already
     * lists an equivalent). */
    RRMode rr_mode;
};

static struct {
    struct wl_display *wl;
    struct zwlr_output_manager_v1 *manager;
    struct zwlr_output_head_v1 *head;
    struct wlr_mode modes[MAX_MODES];
    int n_modes;
    struct zwlr_output_mode_v1 *current;
    uint32_t serial;
    bool have_serial, dirty, finished;

    Display *x;
    Window root;
    RROutput output;
    RRCrtc crtc;
    int rr_event_base;
    /* The last mode this bridge asked the compositor for, so the RandR notification that
     * Xwayland's own resize produces is not fed back as a second request. */
    int32_t asked_w, asked_h, asked_mhz;
    /* The configuration in flight, if any, and its outcome. */
    struct zwlr_output_configuration_v1 *config;
} st;

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...)
{
    char ts[32];
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    strftime(ts, sizeof ts, "%FT%T%z", &tm);
    fprintf(stderr, "%s quasar-display-bridge: ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

/* ---- wlr-output-management client ------------------------------------------------- */

static struct wlr_mode *mode_of(struct zwlr_output_mode_v1 *proxy)
{
    for (int i = 0; i < st.n_modes; i++)
        if (st.modes[i].proxy == proxy)
            return &st.modes[i];
    return NULL;
}

static void mode_size(void *data, struct zwlr_output_mode_v1 *m, int32_t w, int32_t h)
{
    (void)data;
    struct wlr_mode *mode = mode_of(m);
    if (mode) { mode->width = w; mode->height = h; }
}
static void mode_refresh(void *data, struct zwlr_output_mode_v1 *m, int32_t refresh)
{
    (void)data;
    struct wlr_mode *mode = mode_of(m);
    if (mode) mode->refresh_mhz = refresh;
}
static void mode_preferred(void *data, struct zwlr_output_mode_v1 *m)
{
    (void)data;
    struct wlr_mode *mode = mode_of(m);
    if (mode) mode->preferred = true;
}
static void mode_finished(void *data, struct zwlr_output_mode_v1 *m)
{
    (void)data;
    struct wlr_mode *mode = mode_of(m);
    if (mode) mode->finished = true;
    st.dirty = true;
}
static const struct zwlr_output_mode_v1_listener mode_listener = {
    .size = mode_size, .refresh = mode_refresh, .preferred = mode_preferred, .finished = mode_finished,
};

static void head_mode(void *data, struct zwlr_output_head_v1 *h, struct zwlr_output_mode_v1 *m)
{
    (void)data; (void)h;
    if (st.n_modes >= MAX_MODES) {
        logf_("more than %d modes advertised; ignoring the rest", MAX_MODES);
        return;
    }
    struct wlr_mode *mode = &st.modes[st.n_modes++];
    memset(mode, 0, sizeof *mode);
    mode->proxy = m;
    zwlr_output_mode_v1_add_listener(m, &mode_listener, NULL);
    st.dirty = true;
}
static void head_current_mode(void *data, struct zwlr_output_head_v1 *h, struct zwlr_output_mode_v1 *m)
{
    (void)data; (void)h;
    st.current = m;
}
static void head_finished(void *data, struct zwlr_output_head_v1 *h)
{
    (void)data; (void)h;
    logf_("the compositor's head is gone; exiting");
    st.finished = true;
}
static void head_name(void *d, struct zwlr_output_head_v1 *h, const char *n) { (void)d; (void)h; (void)n; }
static void head_description(void *d, struct zwlr_output_head_v1 *h, const char *n) { (void)d; (void)h; (void)n; }
static void head_physical_size(void *d, struct zwlr_output_head_v1 *h, int32_t w, int32_t hh) { (void)d; (void)h; (void)w; (void)hh; }
static void head_enabled(void *d, struct zwlr_output_head_v1 *h, int32_t e) { (void)d; (void)h; (void)e; }
static void head_position(void *d, struct zwlr_output_head_v1 *h, int32_t x, int32_t y) { (void)d; (void)h; (void)x; (void)y; }
static void head_transform(void *d, struct zwlr_output_head_v1 *h, int32_t t) { (void)d; (void)h; (void)t; }
static void head_scale(void *d, struct zwlr_output_head_v1 *h, wl_fixed_t s) { (void)d; (void)h; (void)s; }
static void head_make(void *d, struct zwlr_output_head_v1 *h, const char *n) { (void)d; (void)h; (void)n; }
static void head_model(void *d, struct zwlr_output_head_v1 *h, const char *n) { (void)d; (void)h; (void)n; }
static void head_serial_number(void *d, struct zwlr_output_head_v1 *h, const char *n) { (void)d; (void)h; (void)n; }
static void head_adaptive_sync(void *d, struct zwlr_output_head_v1 *h, uint32_t s) { (void)d; (void)h; (void)s; }

static const struct zwlr_output_head_v1_listener head_listener = {
    .name = head_name, .description = head_description, .physical_size = head_physical_size,
    .mode = head_mode, .enabled = head_enabled, .current_mode = head_current_mode,
    .position = head_position, .transform = head_transform, .scale = head_scale,
    .finished = head_finished, .make = head_make, .model = head_model,
    .serial_number = head_serial_number, .adaptive_sync = head_adaptive_sync,
};

static void manager_head(void *data, struct zwlr_output_manager_v1 *m, struct zwlr_output_head_v1 *h)
{
    (void)data; (void)m;
    if (st.head) {
        /* One output is the compositor's contract; a second head is not ours to manage. */
        logf_("a second head appeared; ignoring it");
        return;
    }
    st.head = h;
    zwlr_output_head_v1_add_listener(h, &head_listener, NULL);
}
static void manager_done(void *data, struct zwlr_output_manager_v1 *m, uint32_t serial)
{
    (void)data; (void)m;
    st.serial = serial;
    st.have_serial = true;
    st.dirty = true;
}
static void manager_finished(void *data, struct zwlr_output_manager_v1 *m)
{
    (void)data; (void)m;
    logf_("the compositor finished the output manager; exiting");
    st.finished = true;
}
static const struct zwlr_output_manager_v1_listener manager_listener = {
    .head = manager_head, .done = manager_done, .finished = manager_finished,
};

static void config_succeeded(void *data, struct zwlr_output_configuration_v1 *c)
{
    (void)data;
    logf_("mode request accepted (%dx%d @ %d mHz); the agent moves the display",
          st.asked_w, st.asked_h, st.asked_mhz);
    zwlr_output_configuration_v1_destroy(c);
    if (st.config == c) st.config = NULL;
}
static void config_failed(void *data, struct zwlr_output_configuration_v1 *c)
{
    (void)data;
    logf_("mode request refused by the compositor (%dx%d @ %d mHz)", st.asked_w, st.asked_h, st.asked_mhz);
    zwlr_output_configuration_v1_destroy(c);
    if (st.config == c) st.config = NULL;
    st.asked_w = st.asked_h = st.asked_mhz = 0;
}
static void config_cancelled(void *data, struct zwlr_output_configuration_v1 *c)
{
    (void)data;
    logf_("mode request cancelled (stale serial); the next RandR change retries");
    zwlr_output_configuration_v1_destroy(c);
    if (st.config == c) st.config = NULL;
    st.asked_w = st.asked_h = st.asked_mhz = 0;
}
static const struct zwlr_output_configuration_v1_listener config_listener = {
    .succeeded = config_succeeded, .failed = config_failed, .cancelled = config_cancelled,
};

static void registry_global(void *data, struct wl_registry *reg, uint32_t name,
                            const char *interface, uint32_t version)
{
    (void)data;
    if (strcmp(interface, zwlr_output_manager_v1_interface.name) == 0 && !st.manager) {
        uint32_t v = version < 4 ? version : 4;
        st.manager = wl_registry_bind(reg, name, &zwlr_output_manager_v1_interface, v);
        zwlr_output_manager_v1_add_listener(st.manager, &manager_listener, NULL);
    }
}
static void registry_global_remove(void *data, struct wl_registry *reg, uint32_t name)
{
    (void)data; (void)reg; (void)name;
}
static const struct wl_registry_listener registry_listener = {
    .global = registry_global, .global_remove = registry_global_remove,
};

/* Ask the compositor for `mode`. */
static void request_mode(struct wlr_mode *mode)
{
    if (!st.have_serial || !st.head) return;
    if (st.config) {
        /* One in flight; the compositor answers every one, so wait for it. */
        logf_("a mode request is still in flight; not sending another");
        return;
    }
    st.asked_w = mode->width;
    st.asked_h = mode->height;
    st.asked_mhz = mode->refresh_mhz;
    st.config = zwlr_output_manager_v1_create_configuration(st.manager, st.serial);
    zwlr_output_configuration_v1_add_listener(st.config, &config_listener, NULL);
    struct zwlr_output_configuration_head_v1 *ch =
        zwlr_output_configuration_v1_enable_head(st.config, st.head);
    zwlr_output_configuration_head_v1_set_mode(ch, mode->proxy);
    zwlr_output_configuration_head_v1_destroy(ch);
    zwlr_output_configuration_v1_apply(st.config);
    wl_display_flush(st.wl);
    logf_("asked the compositor for %dx%d @ %d mHz", mode->width, mode->height, mode->refresh_mhz);
}

/* ---- RandR side ------------------------------------------------------------------- */

static int round_hz(int32_t mhz) { return (int)((mhz + 500) / 1000); }

static double rr_mode_hz(const XRRModeInfo *mi)
{
    if (mi->hTotal == 0 || mi->vTotal == 0) return 0.0;
    double v = mi->vTotal;
    if (mi->modeFlags & RR_DoubleScan) v *= 2;
    if (mi->modeFlags & RR_Interlace) v /= 2;
    return (double)mi->dotClock / ((double)mi->hTotal * v);
}

/* The one output + crtc of a rootful Xwayland (XWAYLAND0). */
static bool find_output(XRRScreenResources *res)
{
    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *oi = XRRGetOutputInfo(st.x, res, res->outputs[i]);
        if (!oi) continue;
        bool connected = oi->connection == RR_Connected;
        RRCrtc crtc = oi->crtc;
        XRRFreeOutputInfo(oi);
        if (connected) {
            st.output = res->outputs[i];
            st.crtc = crtc;
            return true;
        }
    }
    return false;
}

/* Does Xwayland's own (driver) mode list already carry `w x h` at `hz` whole hertz? */
static bool xwayland_has_mode(XRRScreenResources *res, XRROutputInfo *oi, int32_t w, int32_t h, int hz)
{
    for (int i = 0; i < oi->nmode; i++) {
        /* oi->modes lists driver modes first (nmode - npreferred semantics aside), user
         * modes after; a user mode we created carries our name prefix. */
        for (int j = 0; j < res->nmode; j++) {
            XRRModeInfo *mi = &res->modes[j];
            if (mi->id != oi->modes[i]) continue;
            if (mi->nameLength >= 7 && strncmp(mi->name, "quasar-", 7) == 0) continue;
            if ((int32_t)mi->width == w && (int32_t)mi->height == h &&
                (int)(rr_mode_hz(mi) + 0.5) == hz)
                return true;
        }
    }
    return false;
}

/* Mirror the compositor's modes into RandR user modes; retire the ones that are gone. */
static void sync_modes_to_randr(void)
{
    XRRScreenResources *res = XRRGetScreenResourcesCurrent(st.x, st.root);
    if (!res) return;
    if (!find_output(res)) {
        XRRFreeScreenResources(res);
        return;
    }
    XRROutputInfo *oi = XRRGetOutputInfo(st.x, res, st.output);
    if (!oi) {
        XRRFreeScreenResources(res);
        return;
    }

    for (int i = 0; i < st.n_modes; i++) {
        struct wlr_mode *m = &st.modes[i];
        if (m->finished) {
            if (m->rr_mode) {
                XRRDeleteOutputMode(st.x, st.output, m->rr_mode);
                XRRDestroyMode(st.x, m->rr_mode);
                m->rr_mode = 0;
            }
            continue;
        }
        if (m->rr_mode || m->width <= 0 || m->height <= 0 || m->refresh_mhz <= 0) continue;
        int hz = round_hz(m->refresh_mhz);
        if (xwayland_has_mode(res, oi, m->width, m->height, hz)) {
            /* Picking Xwayland's own entry maps back onto this compositor mode by size and
             * nearest refresh (see on_crtc_change), so no duplicate is needed. */
            continue;
        }
        /* A synthetic timing whose vertical refresh is exactly the compositor's: Xwayland
         * never drives a CRTC, the numbers only have to round-trip through RandR. hTotal
         * and vTotal are the active size; the dot clock is width*height*Hz in Hz. */
        char name[64];
        snprintf(name, sizeof name, "quasar-%dx%d@%d.%03d", m->width, m->height,
                 m->refresh_mhz / 1000, m->refresh_mhz % 1000);
        XRRModeInfo mi = {0};
        mi.width = (unsigned)m->width;
        mi.height = (unsigned)m->height;
        mi.hTotal = (unsigned)m->width;
        mi.vTotal = (unsigned)m->height;
        mi.dotClock = (unsigned long)(((uint64_t)m->width * (uint64_t)m->height * (uint64_t)m->refresh_mhz) / 1000);
        mi.hSyncStart = mi.width; mi.hSyncEnd = mi.width;
        mi.vSyncStart = mi.height; mi.vSyncEnd = mi.height;
        mi.name = name;
        mi.nameLength = (unsigned)strlen(name);
        RRMode id = XRRCreateMode(st.x, st.root, &mi);
        if (!id) {
            logf_("XRRCreateMode(%s) failed", name);
            continue;
        }
        XRRAddOutputMode(st.x, st.output, id);
        m->rr_mode = id;
        logf_("listed %s in RandR", name);
    }
    /* Compact finished entries out of the table. */
    int n = 0;
    for (int i = 0; i < st.n_modes; i++) {
        if (st.modes[i].finished) {
            zwlr_output_mode_v1_destroy(st.modes[i].proxy);
            continue;
        }
        st.modes[n++] = st.modes[i];
    }
    st.n_modes = n;
    XRRFreeOutputInfo(oi);
    XRRFreeScreenResources(res);
    XFlush(st.x);
}

/* The user applied a RandR mode: translate it into a compositor mode request. */
static void on_crtc_change(void)
{
    XRRScreenResources *res = XRRGetScreenResourcesCurrent(st.x, st.root);
    if (!res) return;
    if (!find_output(res) || !st.crtc) {
        XRRFreeScreenResources(res);
        return;
    }
    XRRCrtcInfo *ci = XRRGetCrtcInfo(st.x, res, st.crtc);
    if (!ci) {
        XRRFreeScreenResources(res);
        return;
    }
    const XRRModeInfo *mi = NULL;
    for (int i = 0; i < res->nmode; i++)
        if (res->modes[i].id == ci->mode) { mi = &res->modes[i]; break; }
    if (!mi) {
        XRRFreeCrtcInfo(ci);
        XRRFreeScreenResources(res);
        return;
    }
    int32_t w = (int32_t)mi->width, h = (int32_t)mi->height;
    int32_t mhz = (int32_t)(rr_mode_hz(mi) * 1000.0 + 0.5);
    XRRFreeCrtcInfo(ci);
    XRRFreeScreenResources(res);

    /* Xwayland reports its own resize after our request (and after the agent's move) as a
     * CRTC change too; the same mode twice is not a new request. */
    if (w == st.asked_w && h == st.asked_h && abs(mhz - st.asked_mhz) <= 500) return;

    /* The compositor's current mode at this size and rate is where we already are. */
    struct wlr_mode *cur = st.current ? mode_of(st.current) : NULL;
    if (cur && cur->width == w && cur->height == h && abs(cur->refresh_mhz - mhz) <= 500) {
        st.asked_w = w; st.asked_h = h; st.asked_mhz = cur->refresh_mhz;
        return;
    }

    struct wlr_mode *best = NULL;
    for (int i = 0; i < st.n_modes; i++) {
        struct wlr_mode *m = &st.modes[i];
        if (m->width != w || m->height != h) continue;
        if (!best || abs(m->refresh_mhz - mhz) < abs(best->refresh_mhz - mhz)) best = m;
    }
    if (!best) {
        /* One of Xwayland's built-in sizes the monitor does not have: Xwayland has resized
         * its window and the compositor letterboxes it; nothing to ask for. */
        logf_("RandR mode %dx%d is not a display mode; the compositor letterboxes it", w, h);
        return;
    }
    request_mode(best);
}

static int x_error(Display *d, XErrorEvent *e)
{
    (void)d;
    char buf[128];
    XGetErrorText(st.x, e->error_code, buf, sizeof buf);
    logf_("X error: %s (request %d)", buf, e->request_code);
    return 0;
}

int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    const char *parent = getenv("QUASAR_PARENT_WAYLAND_DISPLAY");
    if (!parent || !*parent) {
        logf_("QUASAR_PARENT_WAYLAND_DISPLAY is not set; nothing to bridge");
        return 2;
    }

    st.wl = wl_display_connect(parent);
    if (!st.wl) {
        logf_("cannot connect to the parent compositor at %s: %s", parent, strerror(errno));
        return 1;
    }
    struct wl_registry *reg = wl_display_get_registry(st.wl);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(st.wl);
    if (!st.manager) {
        logf_("the parent compositor has no zwlr_output_manager_v1; display modes stay as Xwayland lists them");
        return 0;
    }
    /* The head burst and the first done. */
    wl_display_roundtrip(st.wl);
    wl_display_roundtrip(st.wl);

    st.x = XOpenDisplay(NULL);
    if (!st.x) {
        logf_("cannot open the X display");
        return 1;
    }
    XSetErrorHandler(x_error);
    st.root = DefaultRootWindow(st.x);
    int rr_error_base;
    if (!XRRQueryExtension(st.x, &st.rr_event_base, &rr_error_base)) {
        logf_("no RandR on this X server");
        return 1;
    }
    XRRSelectInput(st.x, st.root, RRCrtcChangeNotifyMask | RRScreenChangeNotifyMask);
    sync_modes_to_randr();
    st.dirty = false;
    logf_("bridging %d compositor mode(s) to RandR; watching for a pick", st.n_modes);

    struct pollfd fds[2] = {
        { .fd = wl_display_get_fd(st.wl), .events = POLLIN },
        { .fd = ConnectionNumber(st.x), .events = POLLIN },
    };
    while (!st.finished) {
        /* Wayland: prepare-read / poll / read-events is the libwayland dance that lets us
         * also poll the X fd. */
        while (wl_display_prepare_read(st.wl) != 0)
            wl_display_dispatch_pending(st.wl);
        if (wl_display_flush(st.wl) < 0 && errno != EAGAIN) {
            wl_display_cancel_read(st.wl);
            logf_("the compositor connection closed; exiting");
            break;
        }
        int r = poll(fds, 2, -1);
        if (r < 0) {
            wl_display_cancel_read(st.wl);
            if (errno == EINTR) continue;
            logf_("poll: %s", strerror(errno));
            break;
        }
        if (fds[0].revents & POLLIN) {
            if (wl_display_read_events(st.wl) < 0) {
                logf_("the compositor connection closed; exiting");
                break;
            }
        } else {
            wl_display_cancel_read(st.wl);
        }
        if (wl_display_dispatch_pending(st.wl) < 0) {
            logf_("the compositor connection failed; exiting");
            break;
        }
        if (fds[0].revents & (POLLHUP | POLLERR)) break;

        if (st.dirty) {
            sync_modes_to_randr();
            st.dirty = false;
        }

        bool crtc_changed = false;
        while (XPending(st.x)) {
            XEvent ev;
            XNextEvent(st.x, &ev);
            XRRUpdateConfiguration(&ev);
            if (ev.type == st.rr_event_base + RRNotify) {
                XRRNotifyEvent *ne = (XRRNotifyEvent *)&ev;
                if (ne->subtype == RRNotify_CrtcChange) crtc_changed = true;
            } else if (ev.type == st.rr_event_base + RRScreenChangeNotify) {
                crtc_changed = true;
            }
        }
        if (fds[1].revents & (POLLHUP | POLLERR)) {
            logf_("the X connection closed; exiting");
            break;
        }
        if (crtc_changed) on_crtc_change();
    }
    return 0;
}
