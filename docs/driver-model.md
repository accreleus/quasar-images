# Driver model

AMD and Intel use Mesa userspace from Fedora. NVIDIA's kernel driver and matched userspace are injected at runtime by NVIDIA Container Toolkit; this repository does not package either. `quasar-gpu-init` detects the standard injection path and refreshes the dynamic-linker cache without overwriting provided Vulkan ICD or GLVND metadata.

Fedora 43 is pinned by multi-architecture manifest digest in `images/base-fedora/Dockerfile`. Refresh the digest deliberately during the monthly package-baseline review, test it on Tower and Hermes, and record the tested host-driver baselines in the release notes.
