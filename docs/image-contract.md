# Image contract v1

Supported images publish the `org.quasar.image.*` labels described in `contracts/image-contract-v1.schema.json`. Accelerated images must derive from `graphics-fedora`, declare Vulkan/EGL/OpenGL support, and include the Quasar entrypoint, GPU initializer, and GPU probe.

The entrypoint configures the requested UID/GID and runtime directory, runs ordered hooks, initializes injected driver metadata, invokes the probe, then executes the requested command as the unprivileged application user. `QUASAR_GPU_PROBE_ON_STARTUP=0` is reserved for image-local diagnostics and tests; production application launches leave it enabled.

`quasar-gpu-probe` currently fails closed until Milestone 2 supplies exact PCI/UUID matching from Quasar's GPU identity transport. It never permits software renderers.

