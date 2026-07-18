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

# Input-device perms hook: gamepad nodes (udev ID_INPUT_JOYSTICK=1) open to
# 0666; keyboard/mouse/pointer and record-less nodes stay untouched so the
# in-container app can never open (and EVIOCGRAB-starve) the compositor-owned
# virtual keyboard/mouse.
docker run --rm --entrypoint /bin/bash quasar-base:dev -lc '
  set -euo pipefail
  mkdir -p /dev/input /run/udev/data
  mknod /dev/input/event5 c 13 69 && chmod 0600 /dev/input/event5
  mknod /dev/input/event6 c 13 70 && chmod 0600 /dev/input/event6
  mknod /dev/input/event7 c 13 71 && chmod 0600 /dev/input/event7
  mknod /dev/input/event8 c 13 72 && chmod 0600 /dev/input/event8
  mknod /dev/input/event9 c 13 73 && chmod 0600 /dev/input/event9
  printf "E:ID_INPUT=1\nE:ID_INPUT_JOYSTICK=1\n" > /run/udev/data/c13:69
  printf "E:ID_INPUT=1\nE:ID_INPUT_MOUSE=1\n" > /run/udev/data/c13:70
  printf "E:ID_INPUT=1\nE:ID_INPUT_KEYBOARD=1\n" > /run/udev/data/c13:71
  printf "E:ID_INPUT=1\nE:ID_INPUT_JOYSTICK=1\nE:ID_INPUT_KEYBOARD=1\n" > /run/udev/data/c13:73
  /etc/quasar/init.d/15-input-device-perms.sh
  [[ "$(stat -c %a /dev/input/event5)" == 666 ]] # gamepad opened
  [[ "$(stat -c %a /dev/input/event6)" == 600 ]] # mouse untouched
  [[ "$(stat -c %a /dev/input/event7)" == 600 ]] # keyboard untouched
  [[ "$(stat -c %a /dev/input/event8)" == 600 ]] # no udev record: untouched
  [[ "$(stat -c %a /dev/input/event9)" == 600 ]] # joystick+keyboard combo: untouched
'

echo "quasar-base lifecycle checks passed"
