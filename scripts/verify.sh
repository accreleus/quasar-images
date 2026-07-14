#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

for file in contracts/*.json; do jq empty "$file"; done
for file in overlay/usr/local/bin/* images/*/*; do
  [[ -f "$file" && -x "$file" ]] || continue
  bash -n "$file"
done

if grep -nE '^FROM[[:space:]]+[^[:space:]@]+:[^[:space:]]+' images/base-fedora/Dockerfile; then
  echo "base-fedora must use a digest-pinned FROM" >&2
  exit 1
fi
if grep -nE 'gcc|gcc-c\+\+|make|cmake|clang|rust|golang' images/base-fedora/Dockerfile; then
  echo "base-fedora must not contain build dependencies" >&2
  exit 1
fi

./scripts/build.sh base-fedora
./scripts/build.sh graphics-fedora

labels="$(docker image inspect quasar/graphics-fedora:dev --format '{{json .Config.Labels}}')"
jq -e '
  .["org.quasar.image.contract"] == "1" and
  .["org.quasar.image.family"] == "fedora" and
  .["org.quasar.image.acceleration"] == "required" and
  .["org.quasar.image.graphics-apis"] == "vulkan,egl,opengl" and
  .["org.quasar.image.entrypoint"] == "/usr/local/bin/quasar-entrypoint"
' <<<"$labels" >/dev/null

echo "image-local static checks passed"
