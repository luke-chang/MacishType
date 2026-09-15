#!/bin/sh
# Associated-mode selection keys: the host resolves them from its own
# setting and the engine's associatedModeIndexLabels declaration, then
# presents a Shift-gated digit label with a ⇧ prefix. Also pins the
# candidateIndex matching rules the engine side relies on.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

# Key specs are keyval:keycode[:state]; state is a fcitx KeyStates bitmask
# (Shift=1, NumLock=16). KeyA=97:38 commits 中 (dict: 中 -> 文 國 心);
# digit1=49:10, Shift+digit1=33:10:1 (!), Shift+digit4=36:13:1 ($),
# KeyQ=113:24. Keypad 1 is keycode 87: with NumLock off Shift selects level
# 2 and yields KP_1=65457, with NumLock on it yields KP_End=65436.
plain="$("$root/test/Isolated.sh" assocfixture 97:38)"
shift_enter="$("$root/test/Isolated.sh" assocshiftfixture 97:38)"
shift_pick="$("$root/test/Isolated.sh" assocshiftfixture 97:38 33:10:1)"
shift_plain="$("$root/test/Isolated.sh" assocshiftfixture 97:38 49:10)"
shift_over="$("$root/test/Isolated.sh" assocshiftfixture 97:38 36:13:1)"
numpad_off="$("$root/test/Isolated.sh" assocshiftfixture 97:38 65457:87:1)"
numpad_on="$("$root/test/Isolated.sh" assocshiftfixture 97:38 65436:87:17)"
inherit="$("$root/test/Isolated.sh" associnheritfixture 97:38)"
inherit_pick="$("$root/test/Isolated.sh" associnheritfixture 97:38 97:38)"
capped="$("$root/test/Isolated.sh" assoccapfixture 97:38)"
optout="$("$root/test/Isolated.sh" shiftoptoutfixture 97:38 33:10:1)"
mixed_pick="$("$root/test/Isolated.sh" shiftindexfixture 97:38 97:38)"
# An explicit setting overrides the engine either way; refocus rebuilds the
# session so the new value applies (settings land at session boundaries).
forced_shift="$("$root/test/Isolated.sh" assocfixture \
    setaddonopt:macishtype:AssociatedSelectionKeys=shiftNumbers refocus \
    97:38 33:10:1)"
forced_numbers="$("$root/test/Isolated.sh" assocshiftfixture \
    setaddonopt:macishtype:AssociatedSelectionKeys=numbers refocus \
    97:38 49:10)"
# candidateIndex's own rules: the fixture replays them against synthetic
# events and reports through the engine log rather than the panel.
ci_log=/tmp/fcitx5-macishtype-assoc-candidateindex.log
ISOLATED_LOG="$ci_log" "$root/test/Isolated.sh" shiftindexfixture 113:24 \
    > /dev/null
candidate_index="$(cat "$ci_log")"

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" >&2
        exit 1
    fi
}

check_absent() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" >&2
        exit 1
    else
        echo "PASS: $1"
    fi
}

# --- The resolved default: plain digits, no prefix ---
# Neither side declares anything (fixture silent, setting on Follow engine),
# so the host default applies.
check "an undeclaring engine gets plain digit labels" \
    "$plain" '"label": "1 ", "text": "文"'
check_absent "plain digit labels carry no Shift prefix" \
    "$plain" '⇧'

# --- The engine's shiftNumbers declaration ---
check "a shiftNumbers declaration marks the digit labels" \
    "$shift_enter" '"label": "⇧1 ", "text": "文"'
check "Shift + a physical digit key picks the follow-up" \
    "$shift_pick" '{"event": "commit", "text": "中文"}'
check "a plain digit selects nothing and flushes the held char" \
    "$shift_plain" '{"event": "commit", "text": "中"}'
# Three follow-ups on the page, so label 4 is past the item count: the key
# must dismiss rather than be swallowed.
check "Shift + a digit past the page's item count selects nothing" \
    "$shift_over" '{"event": "commit", "text": "中"}'
check "Shift + keypad 1 picks the follow-up (NumLock off)" \
    "$numpad_off" '{"event": "commit", "text": "中文"}'
check "Shift + keypad 1 picks the follow-up (NumLock on)" \
    "$numpad_on" '{"event": "commit", "text": "中文"}'

# --- inherit keeps the engine's own labels ---
check "an inherit declaration keeps the engine's labels" \
    "$inherit" '"label": "a ", "text": "文"'
check "the engine's own label picks the follow-up" \
    "$inherit_pick" '{"event": "commit", "text": "中文"}'

# --- The digit branch caps pageSize at 10 ---
# The fixture declares pageSize 11 and supplies eleven follow-ups.
check "the digit branch caps the page at ten labels" \
    "$capped" '"label": "0 ", "text": "f10"'
check "the eleventh follow-up moves to the next page" \
    "$capped" '"hasNext": true'
check_absent "the eleventh follow-up is not on the first page" \
    "$capped" '"text": "f11"'

# --- handleIndexLabelKeys: false keeps the keys with the engine ---
# The engine commits "ci<index>"; a host that selected the candidate itself
# would commit "c<index>".
check "a Shift-gated digit still reaches an opted-out engine" \
    "$optout" '{"event": "commit", "text": "ci0"}'

# --- Non-digit labels are unaffected by the requirement ---
check "a non-digit label still matches by character" \
    "$mixed_pick" '{"event": "commit", "text": "c0"}'

# --- An explicit host setting wins over the declaration ---
check "the setting forces Shift on an undeclaring engine" \
    "$forced_shift" '{"event": "commit", "text": "中文"}'
check "the setting overrides a shiftNumbers declaration" \
    "$forced_numbers" '{"event": "commit", "text": "中文"}'

# --- candidateIndex matching rules, as engines see them ---
check "the snapshot carries the Shift requirement" \
    "$candidate_index" 'ci-flag true'
check "Shift + a physical digit key answers that digit's label" \
    "$candidate_index" 'ci-event-shift 1'
check "the same physical key without Shift answers nothing" \
    "$candidate_index" 'ci-event-noshift null'
check "a bare digit character never matches while the requirement is on" \
    "$candidate_index" 'ci-string-digit null'
check "an unknown code degrades to character matching" \
    "$candidate_index" 'ci-unknown-code 0'
check "an Option-modified key never selects" \
    "$candidate_index" 'ci-alt null'
echo "Associated-mode selection-key checks passed."
