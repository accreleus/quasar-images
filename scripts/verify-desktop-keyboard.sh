#!/usr/bin/env bash
# verify-desktop-keyboard.sh -- behaviour of quasar-desktop-keyboard, the helper
# the KDE and XFCE launchers run at every start to write the session's keyboard
# layout (XKB_DEFAULT_LAYOUT/_VARIANT) into the desktop's own config
# (accreleus/quasar#850).
#
# Runs the helper from THIS tree against a throwaway HOME: it is plain bash and
# awk, so no image, GPU or desktop is needed. What is pinned:
#   * the layout and variant land in kxkbrc / the xfconf keyboard-layout XML;
#   * a layout the user changed inside the desktop is overwritten, and the rest
#     of the file (other keys, other groups) is kept;
#   * XKB_DEFAULT_LAYOUT unset or empty leaves the desktop's own config alone;
#   * a value outside the control plane's grammar is refused, never written and
#     never run, and the helper still exits 0 (a bad value must not stop a launch);
#   * both launchers call the helper and both Dockerfiles install it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# shellcheck source=scripts/lib/verify-lib.sh
. "$root/scripts/lib/verify-lib.sh"
qv_init

helper="$root/images/desktop-common/quasar-desktop-keyboard"
assert_exec "$helper" "the shared keyboard helper"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
n=0

# run_helper <desktop> [VAR=value ...] -- in a fresh HOME ($home, set here).
# When PRIOR (a path under ~/.config) is set, the home starts with PRIOR_TEXT there.
run_helper() {
  local desktop="$1"; shift
  n=$((n + 1)); home="$work/$n"; mkdir -p "$home"
  if [[ -n "${PRIOR:-}" ]]; then
    mkdir -p "$(dirname "$home/.config/$PRIOR")"
    printf '%s' "$PRIOR_TEXT" >"$home/.config/$PRIOR"
  fi
  env -i PATH="$PATH" HOME="$home" "$@" "$helper" "$desktop" 2>"$work/stderr" \
    || { echo "FAIL: helper exited non-zero for $desktop $*" >&2; cat "$work/stderr" >&2; return 1; }
}

# expect_file <path> <expected text>: exact content, diff on mismatch.
expect_file() {
  local path="$1" want="$2" case_="$3"
  if [[ ! -f "$path" ]]; then echo "FAIL: $case_: $path was not written" >&2; return 1; fi
  if ! diff <(printf '%s' "$want") "$path" >&2; then echo "FAIL: $case_: $path differs (diff above: want < got >)" >&2; return 1; fi
  qv_pass "$case_"
}

kx() { echo "$home/.config/kxkbrc"; }
xf() { echo "$home/.config/xfce4/xfconf/xfce-perchannel-xml/keyboard-layout.xml"; }

xml() {  # xml <layout> <variant>: the channel file, minus its final newline (command substitution drops it)
  printf '<?xml version="1.0" encoding="UTF-8"?>\n\n<channel name="keyboard-layout" version="1.0">\n  <property name="Default" type="empty">\n    <property name="XkbDisable" type="bool" value="false"/>\n    <property name="XkbLayout" type="string" value="%s"/>\n    <property name="XkbVariant" type="string" value="%s"/>\n  </property>\n</channel>\n' "$1" "$2"
}

# --- KDE ---------------------------------------------------------------------
unset PRIOR PRIOR_TEXT
run_helper kde XKB_DEFAULT_LAYOUT=de
expect_file "$(kx)" $'[Layout]\nUse=true\nLayoutList=de\nVariantList=\n' "kde: de, no variant, no prior file"

run_helper kde XKB_DEFAULT_LAYOUT=de XKB_DEFAULT_VARIANT=nodeadkeys
expect_file "$(kx)" $'[Layout]\nUse=true\nLayoutList=de\nVariantList=nodeadkeys\n' "kde: de + nodeadkeys"

# The user last picked two layouts inside Plasma and kept an xkb option and an
# unrelated group: layout keys are replaced, everything else survives.
PRIOR=kxkbrc PRIOR_TEXT=$'[General]\nFoo=bar\n\n[Layout]\nDisplayNames=,\nLayoutList=us,fr\nOptions=caps:escape\nUse=false\nVariantList=,azerty\n\n[Other]\nLayoutList=keep-me\n'
run_helper kde XKB_DEFAULT_LAYOUT=de XKB_DEFAULT_VARIANT=nodeadkeys
expect_file "$(kx)" $'[General]\nFoo=bar\n\n[Layout]\nUse=true\nLayoutList=de\nVariantList=nodeadkeys\nOptions=caps:escape\n\n[Other]\nLayoutList=keep-me\n' \
  "kde: a prior in-desktop layout is overwritten, the rest kept"

PRIOR=kxkbrc PRIOR_TEXT=$'[Layout]\nLayoutList=us\nUse=true\n'
run_helper kde
expect_file "$(kx)" $'[Layout]\nLayoutList=us\nUse=true\n' "kde: unset leaves the desktop's own config untouched"
run_helper kde XKB_DEFAULT_LAYOUT= XKB_DEFAULT_VARIANT=nodeadkeys
expect_file "$(kx)" $'[Layout]\nLayoutList=us\nUse=true\n' "kde: empty layout leaves the desktop's own config untouched"

PRIOR=kxkbrc PRIOR_TEXT=$'[General]\nFoo=bar\n'
run_helper kde XKB_DEFAULT_LAYOUT=fr
expect_file "$(kx)" $'[General]\nFoo=bar\n[Layout]\nUse=true\nLayoutList=fr\nVariantList=\n' "kde: no [Layout] group yet gets one"

unset PRIOR PRIOR_TEXT
run_helper kde
[[ ! -e "$(kx)" ]] || { echo "FAIL: kde: unset created a kxkbrc" >&2; exit 1; }
qv_pass "kde: unset on a fresh home creates nothing"

# --- XFCE --------------------------------------------------------------------
run_helper xfce XKB_DEFAULT_LAYOUT=de
expect_file "$(xf)" "$(xml de '')"$'\n' "xfce: de, no variant, no prior file"

run_helper xfce XKB_DEFAULT_LAYOUT=de XKB_DEFAULT_VARIANT=nodeadkeys
expect_file "$(xf)" "$(xml de nodeadkeys)"$'\n' "xfce: de + nodeadkeys"

# The user switched to US and turned the Xkb settings off in xfce4-keyboard-settings.
PRIOR=xfce4/xfconf/xfce-perchannel-xml/keyboard-layout.xml
PRIOR_TEXT="$(printf '<?xml version="1.0" encoding="UTF-8"?>\n\n<channel name="keyboard-layout" version="1.0">\n  <property name="Default" type="empty">\n    <property name="XkbDisable" type="bool" value="true"/>\n    <property name="XkbLayout" type="string" value="us"/>\n    <property name="XkbVariant" type="string" value="dvorak"/>\n    <property name="XkbOptions" type="empty">\n      <property name="Group" type="string" value="grp:alt_shift_toggle"/>\n    </property>\n  </property>\n  <property name="Other" type="int" value="1"/>\n</channel>\n')"$'\n'
run_helper xfce XKB_DEFAULT_LAYOUT=de XKB_DEFAULT_VARIANT=nodeadkeys
expect_file "$(xf)" "$(printf '<?xml version="1.0" encoding="UTF-8"?>\n\n<channel name="keyboard-layout" version="1.0">\n  <property name="Default" type="empty">\n    <property name="XkbDisable" type="bool" value="false"/>\n    <property name="XkbLayout" type="string" value="de"/>\n    <property name="XkbVariant" type="string" value="nodeadkeys"/>\n    <property name="XkbOptions" type="empty">\n      <property name="Group" type="string" value="grp:alt_shift_toggle"/>\n    </property>\n  </property>\n  <property name="Other" type="int" value="1"/>\n</channel>\n')"$'\n' \
  "xfce: a prior in-desktop layout is overwritten, the rest kept"

before="$PRIOR_TEXT"
run_helper xfce
expect_file "$(xf)" "$before" "xfce: unset leaves the desktop's own config untouched"

unset PRIOR PRIOR_TEXT
run_helper xfce
[[ ! -e "$(xf)" ]] || { echo "FAIL: xfce: unset created a keyboard-layout.xml" >&2; exit 1; }
qv_pass "xfce: unset on a fresh home creates nothing"

# --- values outside the control plane's grammar are never written or run ---------
# shellcheck disable=SC2016  # the $( ) is a literal attack string
for bad in 'de;touch pwned' 'de"/>' 'de$(touch pwned)' 'de ' $'de\nUse=false' 'de,us' "$(printf 'a%.0s' {1..33})"; do
  for d in kde xfce; do
    run_helper "$d" XKB_DEFAULT_LAYOUT="$bad"
    [[ ! -e "$home/.config/kxkbrc" && ! -e "$(xf)" && ! -e "$work/pwned" && ! -e pwned ]] \
      || { echo "FAIL: $d: layout '$bad' was written or executed" >&2; exit 1; }
    grep -q WARNING "$work/stderr" || { echo "FAIL: $d: layout '$bad' was refused without a warning" >&2; exit 1; }
  done
done
run_helper kde XKB_DEFAULT_LAYOUT=de XKB_DEFAULT_VARIANT='x;y'
[[ ! -e "$(kx)" ]] || { echo "FAIL: kde: variant 'x;y' was written" >&2; exit 1; }
qv_pass "bad layout or variant values: refused with a warning, nothing written, exit 0"

# --- wiring --------------------------------------------------------------------
assert_grep '^quasar-desktop-keyboard kde ' images/quasar-kde/quasar-kde "the KDE launcher must run the helper before the session"
assert_grep '^quasar-desktop-keyboard xfce ' images/quasar-xfce/quasar-xfce "the XFCE launcher must run the helper before the session"
for img in kde xfce; do
  assert_grep '^COPY images/desktop-common/quasar-desktop-keyboard /usr/local/bin/quasar-desktop-keyboard$' "images/quasar-$img/Dockerfile" \
    "quasar-$img must install the helper"
  assert_grep 'chmod 0755 .*/usr/local/bin/quasar-desktop-keyboard' "images/quasar-$img/Dockerfile" "the helper must be executable in quasar-$img"
done
qv_pass "both launchers call the helper and both Dockerfiles install it"

qv_pass "quasar-desktop-keyboard behaviour checks passed"
