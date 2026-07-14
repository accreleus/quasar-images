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

RUN dnf --setopt=install_weak_deps=False -y install \
      bash ca-certificates coreutils curl findutils glibc-langpack-en jq procps-ng shadow-utils \
      tini tzdata util-linux \
    && groupadd --gid 1000 quasar \
    && useradd --no-log-init --uid 1000 --gid 1000 --home-dir /home/quasar --create-home --shell /bin/bash quasar \
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

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/quasar-entrypoint"]
CMD ["/bin/bash"]
