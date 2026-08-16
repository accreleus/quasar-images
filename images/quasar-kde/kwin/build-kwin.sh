#!/usr/bin/env bash
set -euo pipefail

# Build a patched kwin RPM set from the DISTRO's own source package.
#
# Runs inside the `kwin-build` stage of images/quasar-kde/Dockerfile (FROM
# fedora:43). It deliberately starts from `dnf download --source kwin` rather
# than an upstream tarball: the shipped image installs Fedora's kwin, so the
# patch has to apply to -- and the resulting RPM has to be
# interchangeable with -- exactly that build (same %files, same subpackages,
# same soname, same dependency set). An upstream tarball build would drift from
# the distro packaging and break `dnf install` over the installed package.
#
# Output: /tmp/kwin-rpms/*.rpm  (binary RPMs only, Release suffixed .quasar1)
#
# See ../README notes and 0001-nested-backend-mode-ladder.patch for WHY the
# patch exists and what re-diffing costs on a Fedora kwin update.

patch_file="${QUASAR_KWIN_PATCH:-/tmp/kwin-patches/0001-nested-backend-mode-ladder.patch}"
out_dir="${QUASAR_KWIN_RPM_DIR:-/tmp/kwin-rpms}"
topdir="${QUASAR_KWIN_TOPDIR:-/tmp/kwin-build}"
# Marks every artifact this script produces, so verify-kde.sh can assert that
# the image runs OUR kwin and not a distro update that silently replaced it.
dist_suffix="${QUASAR_KWIN_DIST_SUFFIX:-.quasar1}"

log() { printf '%s build-kwin: %s\n' "$(date -Iseconds)" "$*" >&2; }

test -f "$patch_file" || { log "FATAL: patch not found at $patch_file"; exit 1; }

log "installing build tooling"
dnf --setopt=install_weak_deps=False -y install \
  rpm-build rpmdevtools 'dnf-command(builddep)' 'dnf-command(download)' patch >/dev/null

mkdir -p "$topdir" "$out_dir"

log "downloading the distro kwin source package"
dnf download --source kwin --destdir="$topdir" >/dev/null
srpm="$(find "$topdir" -maxdepth 1 -name 'kwin-*.src.rpm' | head -1)"
test -n "$srpm" || { log "FATAL: no kwin src.rpm downloaded"; exit 1; }
log "source package: $(basename "$srpm")"

rpm -i "$srpm" --define "_topdir $topdir" 2>&1 | grep -v '^warning:' || true
spec="$topdir/SPECS/kwin.spec"
test -f "$spec" || { log "FATAL: $spec missing after installing the src.rpm"; exit 1; }

# The patch is written against the wayland backend as of 6.7.x. A major version
# bump WILL need a re-diff; fail loudly rather than shipping a half-applied
# backend (see README, "Patched KWin (nested mode ladder)").
version="$(awk '/^Version:/ {print $2; exit}' "$spec")"
log "distro kwin version: $version"
case "$version" in
  6.7.*) : ;;
  *) log "WARNING: patch was written against kwin 6.7.x, this is $version -- re-diff it if the build fails" ;;
esac

log "installing build dependencies (this is the slow part)"
dnf builddep -y --setopt=install_weak_deps=False "$spec" >/dev/null

log "wiring the patch into the spec"
cp "$patch_file" "$topdir/SOURCES/quasar-kwin-mode-ladder.patch"
# %autosetup -p1 applies every PatchN in order, so declaring it is enough --
# there is no %patch line to add. Insert after the last existing Patch/Source
# line so the numbering cannot collide with a distro patch added later.
python3 - "$spec" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
if 'quasar-kwin-mode-ladder.patch' in text:
    sys.exit(0)
nums = [int(m) for m in re.findall(r'^Patch(\d+)\s*:', text, re.M)]
n = max(nums) + 1 if nums else 1000
anchor = list(re.finditer(r'^(?:Patch\d*|Source\d*)\s*:.*$', text, re.M))
if not anchor:
    sys.exit('no Source:/Patch: line found in the spec')
last = anchor[-1]
text = text[:last.end()] + f'\nPatch{n}:  quasar-kwin-mode-ladder.patch' + text[last.end():]
open(path, 'w').write(text)
print(f'declared Patch{n}')
PY

# The build is marked through %dist (below), not by rewriting Release: -- so
# `rpm -q kwin` reports e.g. kwin-6.7.4-1.fc43.quasar1 and verify-kde.sh can
# prove the image runs OUR kwin.
log "building binary RPMs (expect 20-40 minutes)"
rpmbuild -bb "$spec" \
  --define "_topdir $topdir" \
  --define "dist %{?dist}${dist_suffix}" \
  --define "debug_package %{nil}" \
  --nocheck

# debug_package %{nil} should mean there is nothing to skip here, but the copy
# filters anyway: a stray ~700 MB debuginfo RPM landing in the runtime image is
# exactly the kind of regression a lean-image contract exists to prevent.
find "$topdir/RPMS" -name '*.rpm' \
  ! -name '*debuginfo*' ! -name '*debugsource*' \
  -exec cp {} "$out_dir/" \;
built="$(find "$out_dir" -name '*.rpm' | wc -l)"
test "$built" -gt 0 || { log "FATAL: rpmbuild produced no RPMs"; exit 1; }

# Fail the build here rather than in verify-kde.sh if the marker did not land.
if ! find "$out_dir" -name "*${dist_suffix}*.rpm" | grep -q .; then
  log "FATAL: built RPMs carry no ${dist_suffix} release marker; verify-kde.sh could not tell them from the distro package"
  exit 1
fi

log "built $built RPM(s) in $out_dir"
find "$out_dir" -name '*.rpm' -printf '  %f\n' >&2
