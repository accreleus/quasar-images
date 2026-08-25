#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# shellcheck source=scripts/lib/verify-lib.sh
. "$root/scripts/lib/verify-lib.sh"
qv_init

# The image under test. `scripts/build.sh` tags what it builds with
# $QUASAR_IMAGE_TAG (default `dev`), so a verify script that hardcodes `:dev`
# silently checks a DIFFERENT image than the one just built -- which is exactly
# what happened on 2026-08-20: a freshly built quasar-steam passed every
# assertion while this script reported a failure, because it was reading a
# months-old `:dev` left on the box by another branch. Honour the same variable
# the builder uses, and allow an explicit override.
TAG="${QUASAR_IMAGE_TAG:-dev}"
BASE_IMAGE="${QUASAR_BASE_IMAGE_UNDER_TEST:-quasar-base:$TAG}"

assert_grep '^FROM registry\.fedoraproject\.org/fedora@sha256:' images/quasar-base/Dockerfile \
  "the base of the whole family must be digest-pinned, not a floating tag"
# No compiler or build toolchain in the RUNTIME base -- anything that needs one
# builds in a discarded stage (see quasar-steam-runtime's bwrap build).
#
# Two defects, both only visible once the check could fail at all. It was
# `! grep -Eq ...`, and bash does not apply errexit to a `!`-inverted command, so
# it could NEVER fail the script: a toolchain landing in the base would have
# sailed straight through the assertion written to stop it. And its pattern was
# unanchored against the whole file including comments, so the first thing it did
# once made live was match the word "makes" in a prose comment about tini. An
# assertion that is both inert and wrong is worse than none; it reads as cover.
refute_grep_text '(^|[^[:alnum:]_-])(gcc|gcc-c\+\+|make|cmake|clang|rustc|cargo|golang)([^[:alnum:]_.-]|$)' \
  'images/quasar-base/Dockerfile (instructions)' \
  "$(qv_dockerfile_instructions images/quasar-base/Dockerfile)" \
  "no compiler or build toolchain belongs in the runtime base; build it in a discarded stage"
./scripts/build.sh quasar-base
labels="$(docker image inspect "$BASE_IMAGE" --format '{{json .Config.Labels}}')"
jq -e '.["org.quasar.image.contract"] == "1" and .["org.quasar.image.acceleration"] == "optional"' <<<"$labels" >/dev/null
docker run --rm --entrypoint /bin/bash "$BASE_IMAGE" -lc "$QV_GUARD"'
  getent passwd quasar | grep -q "^quasar:x:1000:1000:"
  getent group quasar | grep -q "^quasar:x:1000:"
'

result="$(docker run --rm -e PUID=1234 -e PGID=2345 -e HOME=/home/tester -e UMASK=027 "$BASE_IMAGE" /bin/sh -c 'id -u; id -g; printf "%s %s %s\\n" "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"; stat -c %a "$HOME"')"
[[ "$result" == $'1234\n2345\n/home/tester /home/tester/.config /tmp/quasar-runtime-1234\n750' ]]

# Input-device perms hook: gamepad nodes (udev ID_INPUT_JOYSTICK=1) open to
# 0666; keyboard/mouse/pointer and record-less nodes stay untouched so the
# in-container app can never open (and EVIOCGRAB-starve) the compositor-owned
# virtual keyboard/mouse.
docker run --rm --entrypoint /bin/bash "$BASE_IMAGE" -lc "$QV_GUARD"'
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
