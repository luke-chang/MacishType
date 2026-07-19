#!/bin/sh
# The two client-triggered ways composition ends, each following its
# platform convention:
#   focus-out (window switch) — fcitx5 auto-commits the committable client
#     preedit, so the staged prefix survives (committed exactly once, not
#     duplicated) while the composing rest is dropped.
#   reset (in-app commit, cursor move, select-all) — fcitx5 abandons the
#     input, so the whole composition is discarded.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

commit_count() {
    printf '%s\n' "$1" | grep -c '"event": "commit"' || true
}

# KeyA=97:38 stages 甲; KeyB=98:56 leaves 乙 composing.
staged_focusout="$("$root/test/isolated.sh" stagefixture 97:38 focusout \
    2> /dev/null)"
composing_focusout="$("$root/test/isolated.sh" stagefixture 98:56 focusout \
    2> /dev/null)"
staged_reset="$("$root/test/isolated.sh" stagefixture 97:38 reset \
    2> /dev/null)"
composing_reset="$("$root/test/isolated.sh" stagefixture 98:56 reset \
    2> /dev/null)"

check() {
    if eval "$2"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$3" >&2
        exit 1
    fi
}

check "focus-out commits the staged prefix exactly once" \
    '[ "$(commit_count "$staged_focusout")" = 1 ] &&
     printf "%s\n" "$staged_focusout" |
         grep -qF "{\"event\": \"commit\", \"text\": \"甲\"}"' \
    "$staged_focusout"
check "focus-out discards the composing rest" \
    '[ "$(commit_count "$composing_focusout")" = 0 ]' "$composing_focusout"
check "reset discards staged text (fcitx5 abandon semantics)" \
    '[ "$(commit_count "$staged_reset")" = 0 ]' "$staged_reset"
check "reset discards composing text" \
    '[ "$(commit_count "$composing_reset")" = 0 ]' "$composing_reset"
echo "Composition-end checks passed."
