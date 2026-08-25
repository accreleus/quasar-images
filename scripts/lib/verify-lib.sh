#!/usr/bin/env bash
# scripts/lib/verify-lib.sh — the assertion vocabulary every scripts/verify*.sh
# shares. Source it; do not execute it.
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────────
#
# A verify script is a wall of bare assertions under `set -e`:
#
#     grep -q "FROM fedora:43 AS kwin-build" images/quasar-kde/Dockerfile
#
# When one of those goes stale the script exits 1 having printed NOTHING. There
# is no message, no line number, no clue which of ~40 assertions fired. That is
# not a hypothetical:
#
#   * 2026-08-25, run 32863290838: quasar-kde built cleanly, `build.sh verify
#     quasar-kde` exited 1 after 2.1 s with zero output, and the held stable
#     promotion (PR #26) stalled. The cause was the line above -- the Dockerfile
#     had legitimately stopped saying `FROM fedora:43 AS kwin-build` when the
#     builder base became a digest-pinned ARG and the stage was split into
#     kwin-deps + kwin-build. A correct change; a stale assertion; no diagnostic.
#   * The same failure mode is already annotated IN verify-steam.sh ("silently,
#     since it is a bare assertion with no FAIL message: a failure here aborts
#     the whole script under set -e with no diagnostic"). It was written down and
#     it still recurred, because writing it down does not change what a bare
#     `grep -q` prints.
#
# So the fix is mechanical, not editorial. `qv_init` installs an ERR trap that
# names the file, the line, and the command for EVERY failing assertion --
# including ones nobody remembered to make loud, and including ones written
# after this comment.
#
# ── THE OTHER SILENT FAILURE: `! cmd` IS INERT UNDER errexit ──────────────────
#
# bash does not apply errexit to a command whose status is inverted by `!`, so
#
#     ! grep -Eq 'gcc|clang|rust' images/quasar-base/Dockerfile
#
# can NEVER fail the script. It reads as a negative assertion and is a no-op.
# Several such lines were live in this repo. `refute_grep` / `refute_cmd` are the
# forms that actually fire; use them instead of `!`.
#
# ── ASSERTIONS THAT RUN INSIDE THE IMAGE ──────────────────────────────────────
#
# Most checks here live in a `docker run ... bash -c '<body>'`, where a host-side
# trap cannot reach. $QV_GUARD is that body's preamble: prepend it and the
# in-image assertions report their line and command too. Adjacent string literals
# concatenate, so the edit is one token:
#
#     docker run --rm --entrypoint /bin/bash "$IMG" -lc "$QV_GUARD"'
#       grep -q "KWIN_USE_OVERLAYS=0" /usr/local/bin/quasar-kde
#     '

# set -E so the ERR trap is inherited by functions, subshells and command
# substitutions -- without it a failure inside `$(...)` is silent again, which is
# the exact hole this file exists to close.
set -Eeuo pipefail

qv_init() {
  # ${BASH_SOURCE[0]:-$0}: BASH_SOURCE is empty under `bash -c`, and `set -u`
  # would turn the diagnostic itself into an unbound-variable error.
  trap 'qv__err $? "${BASH_SOURCE[0]:-$0}" "$LINENO" "$BASH_COMMAND"' ERR
}

qv__err() {
  local status="$1" file="$2" line="$3" cmd="$4"
  printf 'FAIL: %s:%s exited %s\n      %s\n' "$file" "$line" "$status" "$cmd" >&2
}

# The preamble for an in-image assertion body. Single-quoted on purpose: $LINENO
# and $BASH_COMMAND must expand in the CONTAINER's shell, not this one.
# `set -Ee` without -u: the existing bodies reference optional variables, and
# turning nounset on for them is a behaviour change, not a diagnostic.
# shellcheck disable=SC2016,SC2034  # expands in the container's shell; used by the sourcing script
QV_GUARD='trap '\''printf "FAIL: in-image assertion at line %s exited %s\n      %s\n" "$LINENO" "$?" "$BASH_COMMAND" >&2'\'' ERR; set -Ee
'

qv_say()  { printf '  %s\n' "$*"; }
qv_pass() { printf 'PASS  %s\n' "$*"; }

# --- probes ------------------------------------------------------------------

# Every executable that must be on PATH inside the image, named as it is checked.
# The bare form of this loop -- `docker run ... -lc "command -v $exe >/dev/null"`
# under set -e -- is silent by construction: `command -v` prints nothing when it
# fails, and neither does docker.
qv_image_has() {
  local image="$1"; shift
  local exe missing=0
  for exe in "$@"; do
    if docker run --rm --entrypoint /bin/bash "$image" -lc "command -v $exe >/dev/null 2>&1"; then
      printf '  ok    %s\n' "$exe"
    else
      printf 'FAIL: %s is not on PATH in %s\n' "$exe" "$image" >&2
      missing=1
    fi
  done
  # Report EVERY missing executable, not just the first: when a base-image
  # refresh drops a package set, "steam, flatpak and firefox are gone" is a
  # different diagnosis from "steam is gone".
  [ "$missing" = 0 ]
}

qv_image_lacks() {
  local image="$1"; shift
  local exe found=0
  for exe in "$@"; do
    if docker run --rm --entrypoint /bin/bash "$image" -lc "command -v $exe >/dev/null 2>&1"; then
      printf 'FAIL: %s is present in %s and must not be\n' "$exe" "$image" >&2
      found=1
    else
      printf '  ok    %s absent\n' "$exe"
    fi
  done
  [ "$found" = 0 ]
}

# --- file assertions ---------------------------------------------------------
#
# `why` is not decoration. It is what the next person reads at 2 a.m. when the
# assertion fires, and it is the difference between "re-diff the patch" and
# "delete the assertion because it looks wrong".

assert_file() {
  local path="$1" why="${2:-}"
  [ -s "$path" ] && return 0
  printf 'FAIL: %s is missing or empty%s\n' "$path" "${why:+ -- $why}" >&2
  return 1
}

assert_exec() {
  local path="$1" why="${2:-}"
  [ -x "$path" ] && return 0
  printf 'FAIL: %s is missing or not executable%s\n' "$path" "${why:+ -- $why}" >&2
  return 1
}

assert_grep() {
  local pattern="$1" file="$2" why="${3:-}"
  grep -Eq -- "$pattern" "$file" && return 0
  printf 'FAIL: %s does not match /%s/%s\n' "$file" "$pattern" "${why:+ -- $why}" >&2
  return 1
}

# The form `! grep ...` cannot express: explicit if/return, so errexit sees it.
refute_grep() {
  local pattern="$1" file="$2" why="${3:-}"
  grep -Eq -- "$pattern" "$file" || return 0
  printf 'FAIL: %s matches /%s/ and must not%s\n' "$file" "$pattern" "${why:+ -- $why}" >&2
  grep -En -- "$pattern" "$file" >&2 || true
  return 1
}

# The same negative assertion against text rather than a file -- for the cases
# where the thing being asserted about is a FILTERED view of a file (Dockerfile
# instructions with the comments stripped, a captured command's output).
refute_grep_text() {
  local pattern="$1" label="$2" text="$3" why="${4:-}"
  grep -Eq -- "$pattern" <<<"$text" || return 0
  printf 'FAIL: %s matches /%s/ and must not%s\n' "$label" "$pattern" "${why:+ -- $why}" >&2
  grep -En -- "$pattern" <<<"$text" >&2 || true
  return 1
}

# A Dockerfile's INSTRUCTIONS, comments stripped. Comments in this repo are long
# and prose-heavy, and matching a package name inside one is a false positive
# that costs a real build -- "makes tini signal only its direct child" contains
# `make`.
qv_dockerfile_instructions() { grep -vE '^[[:space:]]*#' "$1"; }

refute_cmd() {
  local why="$1"; shift
  "$@" >/dev/null 2>&1 || return 0
  printf 'FAIL: `%s` succeeded and must not -- %s\n' "$*" "$why" >&2
  return 1
}
