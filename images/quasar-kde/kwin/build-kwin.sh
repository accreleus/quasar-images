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
# See ../README notes and kwin/*.patch for WHY the patches exist and what
# re-diffing costs on a Fedora kwin update.

# EVERY *.patch in the directory is applied, in sorted (NNNN-) order: the
# patches build on each other (0002 edits code 0001 introduced), so the order is
# load-bearing and adding one is just dropping a file in.
patch_dir="${QUASAR_KWIN_PATCH_DIR:-/tmp/kwin-patches}"
out_dir="${QUASAR_KWIN_RPM_DIR:-/tmp/kwin-rpms}"
topdir="${QUASAR_KWIN_TOPDIR:-/tmp/kwin-build}"
# Marks every artifact this script produces, so verify-kde.sh can assert that
# the image runs OUR kwin and not a distro update that silently replaced it.
dist_suffix="${QUASAR_KWIN_DIST_SUFFIX:-.quasar1}"

log() { printf '%s build-kwin: %s\n' "$(date -Iseconds)" "$*" >&2; }

mapfile -t patches < <(find "$patch_dir" -maxdepth 1 -name '*.patch' | sort)
test "${#patches[@]}" -gt 0 || { log "FATAL: no *.patch found in $patch_dir"; exit 1; }
log "patches to apply: ${patches[*]##*/}"

log "installing build tooling"
dnf --setopt=install_weak_deps=False -y install \
  rpm-build rpmdevtools 'dnf-command(builddep)' 'dnf-command(download)' patch >/dev/null

mkdir -p "$topdir" "$out_dir"

nvr="${QUASAR_KWIN_NVR:-}"
test -n "$nvr" || { log "FATAL: QUASAR_KWIN_NVR is not set (Dockerfile ARG KWIN_NVR)"; exit 1; }

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

log "wiring the patches into the spec"
for patch in "${patches[@]}"; do
  cp "$patch" "$topdir/SOURCES/quasar-$(basename "$patch")"
done
# %autosetup -p1 applies every PatchN in ascending order, so declaring them is
# enough -- there is no %patch line to add. They are declared in sorted filename
# order, which is the order they must apply in. Insert after the last existing
# Patch/Source line so the numbering cannot collide with a distro patch added
# later.
python3 - "$spec" "${patches[@]}" <<'PY'
import os, re, sys
path = sys.argv[1]
names = ['quasar-' + os.path.basename(p) for p in sys.argv[2:]]
text = open(path).read()
declared = []
for name in names:
    if name in text:
        continue
    nums = [int(m) for m in re.findall(r'^Patch(\d+)\s*:', text, re.M)]
    n = max(nums) + 1 if nums else 1000
    anchor = list(re.finditer(r'^(?:Patch\d*|Source\d*)\s*:.*$', text, re.M))
    if not anchor:
        sys.exit('no Source:/Patch: line found in the spec')
    last = anchor[-1]
    text = text[:last.end()] + f'\nPatch{n}:  {name}' + text[last.end():]
    declared.append(f'Patch{n}={name}')
open(path, 'w').write(text)
print('declared ' + ', '.join(declared) if declared else 'nothing to declare')
PY

# The build is marked through %dist (below), not by rewriting Release: -- so
# `rpm -q kwin` reports e.g. kwin-6.7.4-1.fc43.quasar1 and verify-kde.sh can
# prove the image runs OUR kwin.
# %dist must be redefined to a LITERAL: `--define "dist %{?dist}.quasar1"` is a
# recursive declaration and rpm rejects it with "Too many levels of recursion in
# macro expansion".
base_dist="$(rpm --eval '%{?dist}')"
new_dist="${base_dist}${dist_suffix}"
log "release marker: %dist ${base_dist:-<empty>} -> ${new_dist}"

log "building binary RPMs (expect 20-40 minutes)"
rpmbuild -bb "$spec" \
  --define "_topdir $topdir" \
  --define "dist ${new_dist}" \
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
