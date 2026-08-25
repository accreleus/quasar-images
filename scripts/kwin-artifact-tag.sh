#!/usr/bin/env bash
# scripts/kwin-artifact-tag.sh — compute the content tag for the patched-KWin
# RPM artefact.
#
# WHY. Rebuilding Fedora's kwin from its src.rpm with our patches takes 27 of the
# 35 minutes of a full quasar-images CI run (measured: run 31920375541,
# `[kwin-build 4/4] … DONE 1613.4s`). A run that changes nothing about kwin — a
# benchapp tweak, a launcher-script edit, a README — pays all 27 minutes anyway,
# because the build is a stage in quasar-kde's Dockerfile and its only cache is
# whatever the runner happens to have, which on a fresh runner is nothing.
#
# The RPMs are bit-identical whenever their inputs are identical, so they are an
# artefact: build once, publish as ghcr.io/<owner>/quasar-kwin-rpms:<tag>, and
# have quasar-kde bind-mount them from there. This script is the <tag>.
#
# WHAT IS HASHED:
#   1. KWIN_NVR from images/quasar-kde/Dockerfile — the exact Fedora source
#      package the patches are written against.
#   2. KWIN_BUILDER_BASE from the same file — the DIGEST-pinned Fedora image the
#      RPMs are compiled in. This is not decoration. `dnf builddep` resolves
#      against whatever that base's repositories offer, so the same patches
#      compiled on a different Fedora snapshot are a different build: different
#      Qt/KF6 headers, different linkage, and RPM requires strings that may not
#      be satisfiable by the runtime image. Leaving the base unpinned (it was a
#      bare `FROM fedora:43`) meant the tag claimed content-addressing it did not
#      have — two builds with the same tag could contain different RPMs.
#   3. Every images/quasar-kde/kwin/*.patch, by content. A re-diff must produce a
#      new artefact; that is the whole point of the pin.
#   4. images/quasar-kde/kwin/build-kwin*.sh, by content — they decide which
#      builddeps are installed, which patches are applied, the %dist suffix, and
#      the rpmbuild flags. The glob covers the deps/build split.
#
# The builddep SET itself is not enumerated here, and does not need to be: it is
# a pure function of the spec (from KWIN_NVR) and the repositories (from
# KWIN_BUILDER_BASE), both of which are hashed. There is no third input.
#
# NOT hashed: anything else in the repo. A change to the KDE package list or a
# launcher script must NOT invalidate a 27-minute RPM build.
#
# Prints a 16-hex-char tag. Reproducible on macOS and Fedora alike: sha256sum is
# coreutils (absent on macOS), shasum is perl (absent on a minimal Fedora), so
# whichever exists is used.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KWIN_DIR="$REPO_ROOT/images/quasar-kde/kwin"
KDE_DOCKERFILE="$REPO_ROOT/images/quasar-kde/Dockerfile"

if command -v sha256sum >/dev/null 2>&1; then
  sha() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha() { shasum -a 256 | cut -d' ' -f1; }
else
  echo "kwin-artifact-tag: neither sha256sum nor shasum is available" >&2; exit 2
fi

[ -d "$KWIN_DIR" ]        || { echo "kwin-artifact-tag: missing $KWIN_DIR" >&2; exit 2; }
[ -f "$KDE_DOCKERFILE" ]  || { echo "kwin-artifact-tag: missing $KDE_DOCKERFILE" >&2; exit 2; }

arg_of() {
  local v
  v="$(grep -E "^ARG $1=" "$KDE_DOCKERFILE" | head -1 | cut -d= -f2-)"
  [ -n "$v" ] || { echo "kwin-artifact-tag: no 'ARG $1=' in $KDE_DOCKERFILE" >&2; exit 2; }
  printf '%s' "$v"
}

KWIN_NVR="$(arg_of KWIN_NVR)"
KWIN_BUILDER_BASE="$(arg_of KWIN_BUILDER_BASE)"

# A builder base that is not digest-pinned cannot be content-addressed, so the
# artefact tag would be a lie. Refuse rather than emit a tag nobody can trust.
case "$KWIN_BUILDER_BASE" in
  *@sha256:*) ;;
  *) echo "kwin-artifact-tag: KWIN_BUILDER_BASE must be digest-pinned (got '$KWIN_BUILDER_BASE')" >&2; exit 2 ;;
esac

emit_inputs() {
  printf 'kwin_nvr %s\n' "$KWIN_NVR"
  printf 'builder_base %s\n' "$KWIN_BUILDER_BASE"
  local f
  while IFS= read -r f; do
    printf 'patch %s %s\n' "$(basename "$f")" "$(sha < "$f")"
  done < <(find "$KWIN_DIR" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort)
  while IFS= read -r f; do
    printf 'builder %s %s\n' "$(basename "$f")" "$(sha < "$f")"
  done < <(find "$KWIN_DIR" -maxdepth 1 -type f -name 'build-kwin*.sh' | LC_ALL=C sort)
}

INPUTS="$(emit_inputs)"

case "${1:-}" in
  --explain) printf '%s\n' "$INPUTS"; printf -- '---\ntag: %s\n' "$(printf '%s\n' "$INPUTS" | sha | cut -c1-16)" ;;
  ''|--tag)  printf '%s\n' "$INPUTS" | sha | cut -c1-16 ;;
  --nvr)     printf '%s\n' "$KWIN_NVR" ;;
  *) echo "usage: kwin-artifact-tag.sh [--tag|--explain|--nvr]" >&2; exit 64 ;;
esac
