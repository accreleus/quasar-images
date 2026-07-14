# Quasar application base images

`quasar-base` is the shared Fedora 43 runtime for all Quasar application images. It supplies a digest-pinned Fedora base, certificates, timezone/locale support, process and diagnostic tools, a configurable unprivileged user, signal reaping, ordered root init hooks, and managed home/cache/runtime conventions. It intentionally excludes graphics drivers and build toolchains.

```sh
./scripts/build.sh
./scripts/verify.sh
```

The next layers build on `quasar-base`: first graphics, then browser, game, diagnostics, and reference workloads.
