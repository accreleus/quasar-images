#!/usr/bin/env bash
# scripts/graph.sh — read build-graph.json.
#
# The ONLY reader of the build DAG. scripts/build.sh and
# .github/workflows/image-build.yml both go through here, so the build order,
# the build args, the verify wiring, the CI set and the published set are stated
# once in build-graph.json instead of being re-derived (and drifting) in a bash
# case statement and a hardcoded workflow list.
#
# Needs jq. jq is already a hard dependency of every scripts/verify*.sh in this
# repo, is preinstalled on GitHub's ubuntu-latest runners, and is on the devbox.
#
# Usage:
#   graph.sh names                 every image, topological order
#   graph.sh set ci                images with ci=true, topological order
#   graph.sh set publish           images with publish=true, topological order
#   graph.sh set tier:<t>          images in tier <t>, topological order
#   graph.sh order <name>...       the named images and their ancestors, in order
#   graph.sh field <name> <field>  one scalar field (dockerfile, target, tier, ...)
#   graph.sh args <name>           resolved build args, one KEY=VALUE per line
#   graph.sh verify <name>         verify scripts for <name>, one per line
#   graph.sh matrix <selector>     a GitHub Actions matrix JSON array
#   graph.sh check                 validate the graph (unknown deps, cycles, paths)
#
# `<selector>` for set/matrix is `ci`, `publish`, `tier:<t>`, or `ci+tier:<t>`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GRAPH="${QUASAR_BUILD_GRAPH:-$REPO_ROOT/build-graph.json}"

command -v jq >/dev/null 2>&1 || { echo "graph.sh: jq is required (see the header)" >&2; exit 2; }
[ -f "$GRAPH" ] || { echo "graph.sh: missing $GRAPH" >&2; exit 2; }

_names() { jq -r '.images[].name' "$GRAPH"; }
_image() { jq -e --arg n "$1" '.images[] | select(.name == $n)' "$GRAPH"; }

_exists() { _names | grep -qxF "$1"; }

# Topological order. build-graph.json is ALREADY written in a valid order (each
# entry's `needs` name entries defined above it), which `graph.sh check` enforces
# -- so "topological" here is just "file order, filtered". That is deliberate:
# a hand-orderable list a human can read top-to-bottom beats a graph the reader
# has to sort in its head, and check() makes the invariant a build failure rather
# than a convention.
_closure() {
  local wanted=" $* " out=() n
  while true; do
    local grew=0
    for n in $(_names); do
      case "$wanted" in *" $n "*) ;; *) continue ;; esac
      local d
      for d in $(_image "$n" | jq -r '.needs[]?'); do
        case "$wanted" in *" $d "*) ;; *) wanted="$wanted$d "; grew=1 ;; esac
      done
    done
    [ "$grew" = 0 ] && break
  done
  for n in $(_names); do
    case "$wanted" in *" $n "*) out+=("$n") ;; esac
  done
  printf '%s\n' "${out[@]}"
}

_select() {
  case "$1" in
    # `all` and `ci` deliberately EXCLUDE tier=artifact. An artifact is consumed
    # by an image that can also produce it inline (quasar-kde builds the kwin
    # RPMs itself when KWIN_RPMS_IMAGE is not pointed elsewhere), so putting it
    # in the default set would build the same 27-minute rpmbuild twice. Ask for
    # an artifact by name, or via the `artifact` selector.
    all)        jq -r '.images[] | select(.tier != "artifact") | .name' "$GRAPH" ;;
    every)      _names ;;
    artifact)   jq -r '.images[] | select(.tier == "artifact") | .name' "$GRAPH" ;;
    ci)         jq -r '.images[] | select(.ci and .tier != "artifact") | .name' "$GRAPH" ;;
    publish)    jq -r '.images[] | select(.publish) | .name' "$GRAPH" ;;
    tier:*)     jq -r --arg t "${1#tier:}" '.images[] | select(.tier == $t) | .name' "$GRAPH" ;;
    ci+tier:*)  jq -r --arg t "${1#ci+tier:}" '.images[] | select(.ci and .tier == $t) | .name' "$GRAPH" ;;
    *) echo "graph.sh: unknown selector '$1' (all|every|artifact|ci|publish|tier:<t>|ci+tier:<t>)" >&2; exit 64 ;;
  esac
}

# Resolve one `args` value. See build-graph.json's $comment for the vocabulary.
_resolve() {
  local raw="$1" tag="${QUASAR_IMAGE_TAG:-dev}"
  case "$raw" in
    '@version')  tr -d '[:space:]' < "$REPO_ROOT/VERSION" ;;
    '@tag:'*)    printf '%s:%s' "${raw#@tag:}" "$tag" ;;
    '@env:'*)
      local spec="${raw#@env:}" name="${spec%%=*}" default="" v
      case "$spec" in *=*) default="${spec#*=}" ;; esac
      v="$(printf '%s' "${!name:-}")"
      printf '%s' "${v:-$default}"
      ;;
    *) printf '%s' "$raw" ;;
  esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
  names) _names ;;

  set)
    [ $# -eq 1 ] || { echo "usage: graph.sh set <selector>" >&2; exit 64; }
    # Filter file order by the selection -- NOT _closure, because a selection is
    # a set of build targets, and a target whose ancestor is excluded (e.g. a
    # ci=true leaf on a ci=false parent) must surface as an error, not be
    # silently pulled back in. graph.sh check enforces that.
    sel="$(_select "$1")"
    for n in $(_names); do
      if printf '%s\n' "$sel" | grep -qxF "$n"; then printf '%s\n' "$n"; fi
    done
    ;;

  order)
    [ $# -ge 1 ] || { echo "usage: graph.sh order <name>..." >&2; exit 64; }
    for n in "$@"; do _exists "$n" || { echo "graph.sh: no such image '$n'" >&2; exit 64; }; done
    _closure "$@"
    ;;

  field)
    [ $# -eq 2 ] || { echo "usage: graph.sh field <name> <field>" >&2; exit 64; }
    _image "$1" >/dev/null || { echo "graph.sh: no such image '$1'" >&2; exit 64; }
    _image "$1" | jq -r --arg f "$2" '.[$f] // "" | if type == "array" then join(" ") else tostring end'
    ;;

  args)
    [ $# -eq 1 ] || { echo "usage: graph.sh args <name>" >&2; exit 64; }
    _image "$1" >/dev/null || { echo "graph.sh: no such image '$1'" >&2; exit 64; }
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      raw="$(_image "$1" | jq -r --arg k "$k" '.args[$k]')"
      printf '%s=%s\n' "$k" "$(_resolve "$raw")"
    done < <(_image "$1" | jq -r '.args // {} | keys_unsorted[]')
    ;;

  verify)
    [ $# -eq 1 ] || { echo "usage: graph.sh verify <name>" >&2; exit 64; }
    _image "$1" >/dev/null || { echo "graph.sh: no such image '$1'" >&2; exit 64; }
    _image "$1" | jq -r '.verify[]?'
    ;;

  matrix)
    [ $# -eq 1 ] || { echo "usage: graph.sh matrix <selector>" >&2; exit 64; }
    "$0" set "$1" | jq -R . | jq -s -c .
    ;;

  check)
    fail=0
    seen=""
    for n in $(_names); do
      case " $seen " in *" $n "*) echo "duplicate image: $n" >&2; fail=1 ;; esac
      df="$("$0" field "$n" dockerfile)"
      [ -n "$df" ] && [ -f "$REPO_ROOT/$df" ] || { echo "$n: dockerfile '$df' missing" >&2; fail=1; }
      case "$("$0" field "$n" tier)" in
        spine|leaf|artifact) ;;
        *) echo "$n: tier must be spine|leaf|artifact" >&2; fail=1 ;;
      esac
      for d in $(_image "$n" | jq -r '.needs[]?'); do
        _exists "$d" || { echo "$n: needs unknown image '$d'" >&2; fail=1; continue; }
        # Ancestors must be DECLARED EARLIER. This is what makes file order a
        # valid topological order, and it makes a dependency cycle impossible to
        # express -- the check is the whole reason _closure can be this simple.
        case " $seen " in *" $d "*) ;; *) echo "$n: needs '$d', which is declared later (or not at all)" >&2; fail=1 ;; esac
        # A CI image whose parent is not built in CI cannot be built in CI.
        if [ "$("$0" field "$n" ci)" = true ] && [ "$("$0" field "$d" ci)" != true ]; then
          echo "$n: ci=true but its dependency '$d' is ci=false" >&2; fail=1
        fi
      done
      for v in $(_image "$n" | jq -r '.verify[]?'); do
        [ -x "$REPO_ROOT/$v" ] || { echo "$n: verify script '$v' missing or not executable" >&2; fail=1; }
      done
      seen="$seen $n"
    done
    [ "$fail" = 0 ] && echo "build-graph.json OK ($(_names | wc -l | tr -d ' ') images)"
    exit "$fail"
    ;;

  *)
    echo "usage: graph.sh {names|set|order|field|args|verify|matrix|check} ..." >&2
    exit 64
    ;;
esac
