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

# --- an existing file is only ever edited, never replaced or half-written ------
# fresh_home: a new empty $home; run_in_home <desktop> [VAR=value ...] runs the
# helper there (exit 0 required) and leaves its stderr in $work/stderr.
fresh_home() { n=$((n + 1)); home="$work/$n"; mkdir -p "$home/.config"; }
run_in_home() { local d="$1"; shift; run_helper_here "$d" "$@"; }
run_helper_here() {
  local desktop="$1"; shift
  env -i PATH="$PATH" HOME="$home" "$@" "$helper" "$desktop" 2>"$work/stderr" \
    || { echo "FAIL: helper exited non-zero for $desktop $*" >&2; cat "$work/stderr" >&2; return 1; }
}
same_bytes() {  # same_bytes <file> <expected text> <case>
  if ! cmp -s <(printf '%s' "$2") "$1"; then echo "FAIL: $3: $1 changed" >&2; diff <(printf '%s' "$2") "$1" >&2 || true; return 1; fi
  qv_pass "$3"
}
warned() { grep -q WARNING "$work/stderr" || { echo "FAIL: $1: nothing was logged" >&2; cat "$work/stderr" >&2; return 1; }; }

# Another legal spelling of the channel XML (single quotes, attribute order,
# space before '>', one-line leaves, CRLF): Model and Options survive, ours replace the Xkb keys.
fresh_home; mkdir -p "$(dirname "$(xf)")"
printf '<?xml version="1.0" encoding="UTF-8"?>\r\n<channel version="1.0" name="keyboard-layout">\r\n  <property type="empty" name='"'Default'"' >\r\n    <property name="XkbModel" type="string" value="pc105"/>\r\n    <property name='"'XkbLayout'"' type="string" value="us" />\r\n    <property name="XkbOptions" type="empty">\r\n      <property name="Group" type="string" value="grp:alt_shift_toggle"/>\r\n    </property>\r\n    <property name="XkbDisable" type="bool" value="true"/>\r\n  </property>\r\n</channel>\r\n' >"$(xf)"
run_in_home xfce XKB_DEFAULT_LAYOUT=de XKB_DEFAULT_VARIANT=nodeadkeys
for want in 'name="XkbModel" type="string" value="pc105"' 'grp:alt_shift_toggle' 'name="XkbLayout" type="string" value="de"' 'name="XkbVariant" type="string" value="nodeadkeys"' 'name="XkbDisable" type="bool" value="false"'; do
  grep -qF -- "$want" "$(xf)" || { echo "FAIL: xfce other spelling: missing $want" >&2; cat "$(xf)" >&2; exit 1; }
done
[[ "$(grep -c 'XkbLayout' "$(xf)")" == 1 && "$(grep -c 'XkbDisable' "$(xf)")" == 1 && "$(grep -c value=\"us\" "$(xf)")" == 0 && "$(grep -c value=\"true\" "$(xf)")" == 0 ]] \
  || { echo "FAIL: xfce other spelling: an old Xkb key survived or doubled" >&2; cat "$(xf)" >&2; exit 1; }
qv_pass "xfce: another legal spelling keeps XkbModel/XkbOptions and replaces only the layout keys"

# An existing channel file that cannot be edited safely is left byte-identical.
for odd in '<channel name="keyboard-layout" version="1.0">
  <property name="Default" type="empty"/>
</channel>
' '<channel name="keyboard-layout" version="1.0">
  <property name="Default" type="empty">
    <property name="XkbLayout" type="string"
      value="us"/>
  </property>
</channel>
'; do
  fresh_home; mkdir -p "$(dirname "$(xf)")"; printf '%s' "$odd" >"$(xf)"
  run_in_home xfce XKB_DEFAULT_LAYOUT=de
  same_bytes "$(xf)" "$odd" "xfce: a shape the edit cannot handle is left byte-identical"; warned "xfce unmergeable"
done

# Unreadable, a directory or a symlink where the file should be: byte-identical, nothing written, still exit 0.
fresh_home; printf '[Layout]\nLayoutList=us\nOptions=caps:escape\n' >"$home/.config/kxkbrc"; chmod 000 "$home/.config/kxkbrc"
mkdir -p "$(dirname "$(xf)")"; printf '<channel name="keyboard-layout" version="1.0">\n  <property name="Default" type="empty">\n    <property name="XkbOptions" type="string" value="x"/>\n  </property>\n</channel>\n' >"$(xf)"; chmod 000 "$(xf)"
if [[ -r "$home/.config/kxkbrc" ]]; then
  echo "SKIP  unreadable-file cases: running as a user that ignores file modes"
else
  run_in_home kde XKB_DEFAULT_LAYOUT=de; warned "kde unreadable"
  run_in_home xfce XKB_DEFAULT_LAYOUT=de; warned "xfce unreadable"
  chmod 600 "$home/.config/kxkbrc" "$(xf)"
  same_bytes "$home/.config/kxkbrc" $'[Layout]\nLayoutList=us\nOptions=caps:escape\n' "kde: an unreadable kxkbrc is left byte-identical"
  grep -q 'XkbOptions' "$(xf)" && [[ "$(grep -c XkbLayout "$(xf)")" == 0 ]] || { echo "FAIL: xfce: unreadable file was rewritten" >&2; exit 1; }
  for stray in "$home/.config/kxkbrc".?????? "$(xf)".??????; do
    [[ ! -e "$stray" ]] || { echo "FAIL: a temp file was left behind: $stray" >&2; exit 1; }
  done
  qv_pass "xfce: an unreadable channel file is left byte-identical"
fi
fresh_home; mkdir "$home/.config/kxkbrc"
run_in_home kde XKB_DEFAULT_LAYOUT=de; warned "kde directory"
[[ -d "$home/.config/kxkbrc" ]] || { echo "FAIL: a directory named kxkbrc was replaced" >&2; exit 1; }
qv_pass "kde: a non-regular kxkbrc is left alone"

fresh_home; printf '[Layout]\nLayoutList=us\n' >"$work/real-kxkbrc"; ln -s "$work/real-kxkbrc" "$home/.config/kxkbrc"
run_in_home kde XKB_DEFAULT_LAYOUT=de; warned "kde symlink"
[[ -L "$home/.config/kxkbrc" ]] || { echo "FAIL: the kxkbrc symlink was replaced" >&2; exit 1; }
same_bytes "$work/real-kxkbrc" $'[Layout]\nLayoutList=us\n' "kde: a symlinked kxkbrc is left alone (link and target)"

# The file's own mode is kept; a new file is 0644.
fresh_home; printf '[Layout]\nLayoutList=us\n' >"$home/.config/kxkbrc"; chmod 600 "$home/.config/kxkbrc"
run_in_home kde XKB_DEFAULT_LAYOUT=de
[[ "$(stat -c %a "$home/.config/kxkbrc")" == 600 ]] || { echo "FAIL: kde: a 0600 kxkbrc was widened" >&2; exit 1; }
fresh_home; mkdir -p "$(dirname "$(xf)")"; xml us '' >"$(xf)"; chmod 600 "$(xf)"
run_in_home xfce XKB_DEFAULT_LAYOUT=de
[[ "$(stat -c %a "$(xf)")" == 600 ]] || { echo "FAIL: xfce: a 0600 channel file was widened" >&2; exit 1; }
fresh_home; run_in_home kde XKB_DEFAULT_LAYOUT=de
[[ "$(stat -c %a "$home/.config/kxkbrc")" == 644 ]] || { echo "FAIL: kde: a new kxkbrc is not 0644" >&2; exit 1; }
qv_pass "an existing file keeps its mode; a new one is 0644"

# KDE: 'Key = value' spacing, CRLF and indentation; never a second [Layout] group.
fresh_home; printf '[General]\r\nFoo=bar\r\n\r\n[Layout]\r\nLayoutList = us,fr\r\n  Use = false\r\nVariantList =,\r\nOptions=caps:escape\r\n' >"$home/.config/kxkbrc"
run_in_home kde XKB_DEFAULT_LAYOUT=de XKB_DEFAULT_VARIANT=nodeadkeys
same_bytes "$home/.config/kxkbrc" $'[General]\r\nFoo=bar\r\n\r\n[Layout]\r\nUse=true\r\nLayoutList=de\r\nVariantList=nodeadkeys\r\nOptions=caps:escape\r\n' \
  "kde: spaced keys and CRLF are replaced in the one [Layout] group"

# A refusal leaves an existing file byte-identical (both desktops).
for bad in 'de;touch pwned' 'de"/>'; do
  fresh_home; mkdir -p "$(dirname "$(xf)")"
  printf '[Layout]\nLayoutList=us\n' >"$home/.config/kxkbrc"; printf '<channel name="keyboard-layout" version="1.0"/>\n' >"$(xf)"
  run_in_home kde XKB_DEFAULT_LAYOUT="$bad"; run_in_home xfce XKB_DEFAULT_LAYOUT="$bad"
  same_bytes "$home/.config/kxkbrc" $'[Layout]\nLayoutList=us\n' "kde: refusing '$bad' leaves kxkbrc byte-identical"
  same_bytes "$(xf)" $'<channel name="keyboard-layout" version="1.0"/>\n' "xfce: refusing '$bad' leaves the channel file byte-identical"
done

# --- wiring --------------------------------------------------------------------
assert_grep '^quasar-desktop-keyboard kde ' images/quasar-kde/quasar-kde "the KDE launcher must run the helper before the session"
assert_grep '^quasar-desktop-keyboard xfce ' images/quasar-xfce/quasar-xfce "the XFCE launcher must run the helper before the session"
for img in kde xfce; do
  assert_grep '^COPY images/desktop-common/quasar-desktop-keyboard /usr/local/bin/quasar-desktop-keyboard$' "images/quasar-$img/Dockerfile" \
    "quasar-$img must install the helper"
  assert_grep 'chmod 0755 .*/usr/local/bin/quasar-desktop-keyboard' "images/quasar-$img/Dockerfile" "the helper must be executable in quasar-$img"
done
qv_pass "both launchers call the helper and both Dockerfiles install it"

# The call is soft (a failing helper must not fail the launch) and comes before
# the session starts: run each launcher's real call line under the launchers' own
# `set -euo pipefail` with a helper that fails, and compare line positions.
mkdir -p "$work/failing"; printf '#!/bin/sh\nexit 1\n' >"$work/failing/quasar-desktop-keyboard"; chmod 755 "$work/failing/quasar-desktop-keyboard"
for d in kde xfce; do
  launcher="images/quasar-$d/quasar-$d"
  call="$(grep -E "^quasar-desktop-keyboard $d " "$launcher")"
  [[ -n "$call" ]] || { echo "FAIL: $launcher has no call line" >&2; exit 1; }
  out="$(PATH="$work/failing:$PATH" bash -c 'set -euo pipefail; log() { printf "logged: %s\n" "$*"; }; '"$call"'; echo survived' 2>&1)" \
    || { echo "FAIL: $d: a failing helper failed the launch: $out" >&2; exit 1; }
  grep -q '^survived$' <<<"$out" && grep -q '^logged: WARNING' <<<"$out" \
    || { echo "FAIL: $d: the soft guard did not log and continue: $out" >&2; exit 1; }
  call_line="$(grep -nE "^quasar-desktop-keyboard $d " "$launcher" | head -1 | cut -d: -f1)"
  start_line="$(grep -nE '^"\$\{session\[@\]\}" &' "$launcher" | head -1 | cut -d: -f1)"
  (( call_line < start_line )) || { echo "FAIL: $d: the helper runs after the session starts ($call_line >= $start_line)" >&2; exit 1; }
done
qv_pass "a failing helper does not fail either launcher, and runs before the session starts"

qv_pass "quasar-desktop-keyboard behaviour checks passed"
