# Fedora 43 multi-architecture index, selected 2026-07-14.
FROM registry.fedoraproject.org/fedora@sha256:711261231459f5ebc6694f7eb2b4b427b87fb6272df8b6663cb4bcbdbb220e9f

ARG VERSION=0.1.0-dev

LABEL org.opencontainers.image.title="Quasar common Fedora base" \
      org.opencontainers.image.vendor="Quasar" \
      org.quasar.image.contract="1" \
      org.quasar.image.family="fedora" \
      org.quasar.image.base.version="${VERSION}" \
      org.quasar.image.acceleration="optional" \
      org.quasar.image.entrypoint="/usr/local/bin/quasar-entrypoint"

# fuse3 (fusermount3): xdg-desktop-portal's document portal mounts its
# fuse filesystem for sandboxed apps' file-chooser access; without it the
# portal's fuse mount fails on every image in this family.
RUN dnf --setopt=install_weak_deps=False -y install \
      bash ca-certificates coreutils curl findutils fuse3 glibc-langpack-en jq procps-ng shadow-utils \
      tini tzdata util-linux \
    && groupadd --gid 1000 quasar \
    && useradd --no-log-init --uid 1000 --gid 1000 --home-dir /home/quasar --create-home --shell /bin/bash quasar \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# NOT DONE HERE, AND HERE IS WHY (measured 2026-08-20, so nobody re-tries it).
#
# /usr/share/locale is 53 MB in this image and the audit proposed pruning it to
# `en*` here, on the reasoning that the whole family inherits the saving --
# "53 MB x every image", ~0.5 GB across the set.
#
# It saves NOTHING. The locales are not installed by the dnf layer above; they
# come with the 191 MB `KIWI 10.3.0` Fedora base layer that this image is FROM.
# Deleting them in a child layer writes whiteouts over bytes that still travel in
# the parent: built and measured, this image stayed at 290 MB and its dnf layer
# grew 22.6 -> 22.7 MB for the whiteout entries. `du /usr/share/locale` inside the
# container drops to 1.5 MB, which is exactly the misleading part -- the
# filesystem looks trimmed while the image is not.
#
# The same applies to every descendant: quasar-app's own packages add ~0 MB of
# locale (53 MB in both quasar-base and quasar-app), so pruning in their layers
# would not help either.
#
# The only real fix is to stop the base from carrying them -- `%_install_langs`
# at Fedora KIWI build time, which is upstream's image, not ours -- or to accept
# 53 MB. Accepting it.
#
# Where a locale prune DOES pay is a layer that installs its own packages: see
# the runtime trim in the quasar repo's deploy/Dockerfile.vulkan, which prunes in
# the same RUN as its own dnf install.

COPY overlay/usr/local/bin/quasar-entrypoint /usr/local/bin/quasar-entrypoint
COPY overlay/etc/quasar/init.d/ /etc/quasar/init.d/

RUN chmod 0755 /usr/local/bin/quasar-entrypoint \
    && mkdir -p /var/lib/quasar /var/cache/quasar /etc/quasar/init.d \
    && chmod 0755 /var/lib/quasar /var/cache/quasar

ENV HOME=/home/quasar \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    PUID=1000 \
    PGID=1000 \
    UMASK=022 \
    UNAME=quasar

# Plain tini (no -g): tini tolerates only ESRCH from kill() and treats EPERM as
# fatal, so a -g group-kill against an unprivileged (--cap-drop ALL, no CAP_KILL)
# reshaped process group aborts the container outright (reconstructed 6551fe8
# FATAL: "[FATAL tini (1)] Unexpected error when forwarding signal: 'Operation
# not permitted'"). Dropping -g makes tini signal only its direct child, which
# structurally can never hit that EPERM class. Graceful shutdown is instead the
# launcher's job: it owns a sequenced TERM relay to its own children (see
# images/quasar-steam/quasar-steam's on_term()). `docker stop`'s SIGKILL-after-
# timeout remains the backstop for anything a launcher's relay misses; tini's
# subreaper orphan-reaping is unaffected by dropping -g.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/quasar-entrypoint"]
CMD ["/bin/bash"]
