#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

[[ "$(grep -c '^FROM registry.fedoraproject.org/fedora:43$' images/quasar-base/Dockerfile)" == "1" ]]
[[ "$(wc -l < images/quasar-base/Dockerfile | tr -d ' ')" == "1" ]]
./scripts/build.sh
docker image inspect quasar-base:dev --format '{{.Os}}/{{.Architecture}} {{.Config.Cmd}}'
