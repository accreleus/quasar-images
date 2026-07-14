# Quasar application base images

Versioned Fedora application image bases for [Quasar](https://github.com/Quasar-Project/quasar).

This repository owns application-side graphics runtime, lifecycle, diagnostics and image contracts. GPU scheduling, device exposure and session orchestration stay in the main Quasar repository.

## Quick start

Docker is the only required host tool.

```sh
./scripts/build.sh base-fedora
./scripts/build.sh graphics-fedora
./scripts/verify.sh
```

`graphics-fedora`, `browser-fedora`, `game-fedora`, `diagnostics`, `test-vulkan`, and `test-egl` are build targets. The browser, diagnostic and reference-workload layers are intentionally small initial scaffolds; vendor validation and accelerated workloads land in the next implementation milestone.

See [the image contract](docs/image-contract.md), [driver model](docs/driver-model.md), and [adding an image](docs/adding-an-image.md).
