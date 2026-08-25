#!/usr/bin/env bash
set -euo pipefail

# The EXPENSIVE, RARELY-CHANGING half of the patched-kwin build: fetch the pinned
# source package and install its build dependencies (~1.5 GB of Qt/KF6 -devel).
#
# Runs as the `kwin-deps` stage of images/quasar-kde/Dockerfile. build-kwin.sh --
# the cheap, frequently-changing half -- runs in a stage FROM this one and
# inherits the populated %_topdir.
#
# WHY THE SPLIT. Everything here is a function of two pins: KWIN_NVR and the
# digest-pinned KWIN_BUILDER_BASE. Nothing else can change it. The patches, by
# contrast, change every time the nested backend is touched, and before the split
# a one-line patch edit invalidated the layer that installs 1.5 GB of build
# dependencies -- the patches were COPYed in before builddep ran, so BuildKit's
# cache key for the whole thing included them. Re-diffing a patch cost the
# dependency install again, every time, on every box.
#
# Now: edit a patch -> only build-kwin.sh's layer misses. Bump KWIN_NVR or the
# builder base -> both miss, which is correct, because a different source package
# genuinely has different build dependencies.
#
# It deliberately starts from `dnf download --source kwin` rather than an
# upstream tarball: the shipped image installs Fedora's kwin, so the patch has to
# apply to -- and the resulting RPM has to be interchangeable with -- exactly
# that build (same %files, same subpackages, same soname, same dependency set).
# An upstream tarball build would drift from the distro packaging and break
# `dnf install` over the installed package.
#
# Output: a populated ${QUASAR_KWIN_TOPDIR} (SOURCES/ + SPECS/kwin.spec) with
# every builddep installed. No RPMs are built here.

topdir="${QUASAR_KWIN_TOPDIR:-/tmp/kwin-build}"

log() { printf '%s build-kwin-deps: %s\n' "$(date -Iseconds)" "$*" >&2; }

nvr="${QUASAR_KWIN_NVR:-}"
test -n "$nvr" || { log "FATAL: QUASAR_KWIN_NVR is not set (Dockerfile ARG KWIN_NVR)"; exit 1; }

log "installing build tooling"
dnf --setopt=install_weak_deps=False -y install \
  rpm-build rpmdevtools 'dnf-command(builddep)' 'dnf-command(download)' patch >/dev/null

mkdir -p "$topdir"

log "downloading the pinned kwin source package: kwin-${nvr}"
if ! dnf download --source "kwin-${nvr}" --destdir="$topdir" >/dev/null 2>&1; then
  log "FATAL: kwin-${nvr}.src.rpm is not available in the configured repositories."
  log "       Fedora has almost certainly moved kwin on. The patch is version-specific:"
  log "       re-diff it against the new source, then bump ARG KWIN_NVR in"
  log "       images/quasar-kde/Dockerfile. See the README, 'Patched KWin (nested mode ladder)'."
  log "       available: $(dnf list --showduplicates kwin 2>/dev/null | awk '/^kwin\./ {print $2}' | tr '\n' ' ')"
  exit 1
fi
srpm="$(find "$topdir" -maxdepth 1 -name 'kwin-*.src.rpm' | head -1)"
test -n "$srpm" || { log "FATAL: no kwin src.rpm downloaded"; exit 1; }
log "source package: $(basename "$srpm")"

rpm -i "$srpm" --define "_topdir $topdir" 2>&1 | grep -v '^warning:' || true
spec="$topdir/SPECS/kwin.spec"
test -f "$spec" || { log "FATAL: $spec missing after installing the src.rpm"; exit 1; }

# HARD fail on any drift from the pin. The patch is written against one exact
# source tree; a mismatch means it is being applied to something it was never
# reviewed against, and `patch` applying with fuzz is a worse outcome than a
# failed build (see README, "Patched KWin (nested mode ladder)").
srpm_nvr="$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$srpm" 2>/dev/null)"
if [[ "$srpm_nvr" != "$nvr" ]]; then
  log "FATAL: source package is kwin-${srpm_nvr}, but the pin is kwin-${nvr}."
  log "       Re-diff the patch and bump ARG KWIN_NVR in images/quasar-kde/Dockerfile."
  exit 1
fi
log "source package NVR matches the pin: ${srpm_nvr}"

log "installing build dependencies (this is the slow part)"
dnf builddep -y --setopt=install_weak_deps=False "$spec" >/dev/null

log "done; %_topdir is ${topdir}"
