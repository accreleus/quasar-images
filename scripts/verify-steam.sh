#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

for executable in steam gamescope bwrap quasar-steam quasar-steam-client; do
  docker run --rm --entrypoint /bin/bash quasar-steam:dev -lc "command -v $executable >/dev/null"
done

docker run --rm --entrypoint /bin/bash quasar-steam:dev -lc '
  grep -q -- "-gamepadui" /usr/local/bin/quasar-steam-client
  grep -q "exec gamescope" /usr/local/bin/quasar-steam
  grep -q "QUASAR_STEAM_GAMESCOPE:-1" /usr/local/bin/quasar-steam
'

labels="$(docker image inspect quasar-steam:dev --format '{{json .Config.Labels}}')"
jq -e '.["org.quasar.image.contract"] == "1" and .["org.quasar.image.acceleration"] == "required"' <<<"$labels" >/dev/null

echo "quasar-steam structural checks passed"
