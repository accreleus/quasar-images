# Quasar application base images

The first implementation step is a clean Fedora 43 base image. It is built and inspected on Tower before any lifecycle, graphics, browser, game, or CI layer is introduced.

```sh
./scripts/build.sh
./scripts/verify.sh
```
