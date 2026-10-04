# Built inside the quasar-app image build (a throwaway builder stage); nothing here is
# run on a host. wayland-scanner turns the wlr XML (Fedora's wlr-protocols-devel) into the
# client header + glue; the rest is libwayland-client + libX11 + libXrandr.
PROTO ?= /usr/share/wlr-protocols/unstable/wlr-output-management-unstable-v1.xml
CFLAGS ?= -O2 -Wall -Wextra -std=gnu11
PKGS = wayland-client x11 xrandr

all: quasar-display-bridge

wlr-output-management-unstable-v1-client-protocol.h: $(PROTO)
	wayland-scanner client-header $< $@

wlr-output-management-unstable-v1-protocol.c: $(PROTO)
	wayland-scanner private-code $< $@

quasar-display-bridge: quasar-display-bridge.c wlr-output-management-unstable-v1-protocol.c wlr-output-management-unstable-v1-client-protocol.h
	$(CC) $(CFLAGS) $$(pkg-config --cflags $(PKGS)) -o $@ quasar-display-bridge.c wlr-output-management-unstable-v1-protocol.c $$(pkg-config --libs $(PKGS))

clean:
	rm -f quasar-display-bridge wlr-output-management-unstable-v1-protocol.c wlr-output-management-unstable-v1-client-protocol.h
