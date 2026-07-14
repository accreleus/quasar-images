#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

grep -q '^FROM registry.fedoraproject.org/fedora@sha256:' images/quasar-base/Dockerfile
! grep -Eq 'gcc|gcc-c\+\+|make|cmake|clang|rust|golang' images/quasar-base/Dockerfile
./scripts/build.sh quasar-base
labels="$(docker image inspect quasar-base:dev --format '{{json .Config.Labels}}')"
jq -e '.["org.quasar.image.contract"] == "1" and .["org.quasar.image.acceleration"] == "optional"' <<<"$labels" >/dev/null
docker run --rm --entrypoint /bin/bash quasar-base:dev -lc '
  getent passwd quasar | grep -q "^quasar:x:1000:1000:"
  getent group quasar | grep -q "^quasar:x:1000:"
'

result="$(docker run --rm -e PUID=1234 -e PGID=2345 -e HOME=/home/tester -e UMASK=027 quasar-base:dev /bin/sh -c 'id -u; id -g; printf "%s %s %s\\n" "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"; stat -c %a "$HOME"')"
[[ "$result" == $'1234\n2345\n/home/tester /home/tester/.config /tmp/quasar-runtime-1234\n750' ]]

echo "quasar-base lifecycle checks passed"
