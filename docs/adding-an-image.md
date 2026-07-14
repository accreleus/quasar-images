# Adding an image

Build on the narrowest appropriate base: `base-fedora` for non-accelerated support processes, `graphics-fedora` for GPU clients, `browser-fedora` for Chromium applications, and `game-fedora` for game dependency layers. Do not add compilers, Steam, Proton, a host driver, or a specific launcher to common bases.

Use `./scripts/build.sh <target>` and `./scripts/verify.sh` before proposing a layer. Hardware images must also pass the vendor checks when those are implemented.

