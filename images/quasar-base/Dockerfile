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
    # Non-English locales, ~53 MB, in the SAME layer as the install that brought
    # them -- an overlay delete in a later RUN hides bytes but never reclaims them,
    # so a tidier separate layer would save exactly nothing.
    #
    # This is the base of the whole family, so the saving lands in quasar-app,
    # quasar-steam-runtime, quasar-steam, quasar-kde, quasar-diagnostics,
    # quasar-benchapp and quasar-unigine alike -- roughly 0.5 GB across the set.
    #
    # `glibc-langpack-en` above is what provides en_US.UTF-8, which is what LANG and
    # LC_ALL are set to below; keeping `en*` keeps that intact. A session that needs
    # another language wants its own langpack installed, not 200 of them shipped on
    # the chance one is used. Verified with `locale -a` after the change.
    && find /usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en*' -exec rm -rf {} + \
    && locale -a | grep -q '^en_US.utf8$' \
    && dnf clean all \
    && rm -rf /var/cache/dnf

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
