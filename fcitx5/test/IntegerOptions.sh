#!/bin/sh
# Integer options that are not plain in-range integers. NaN reads as omitted,
# like a value of another type; fractions truncate, and a number beyond an
# int, either infinity included, saturates rather than wrapping, before each
# field applies its own clamp. jshost/tests/RunContractTests.py does NOT
# parse this file (the decoding lives in the fcitx5 session).
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -20 >&2
        exit 1
    fi
}

last_preedit() {
    printf '%s\n' "$1" | grep '"event": "preedit"' | tail -1
}

last_cand() {
    printf '%s\n' "$1" | grep '"event": "candidates"' | tail -1
}

# Keysym:keycode pairs for KeyA through KeyF; see the fixture for what each
# key sends. "xyz" is three clusters and three bytes, so its end is caret 3.
nan_cursor="$(last_preedit "$("$root/test/Isolated.sh" intoptfixture 97:38)")"
huge_cursor="$(last_preedit "$("$root/test/Isolated.sh" intoptfixture 98:56)")"
staged="$("$root/test/Isolated.sh" intoptfixture 99:54)"
emphasis="$(last_preedit "$("$root/test/Isolated.sh" intoptfixture 100:40)")"
high="$(last_cand "$("$root/test/Isolated.sh" intoptfixture 101:26)")"
low="$(last_cand "$("$root/test/Isolated.sh" intoptfixture 102:41)")"

check "a NaN cursor is omitted, leaving the caret at the end" \
    "$nan_cursor" '"cursor": 3'
check "a cursor of 2 ** 32 clamps to the end instead of wrapping to 0" \
    "$huge_cursor" '"cursor": 3'
check "staging Infinity stages the whole text" \
    "$staged" '"event": "commit", "text": "xyz"'
# Segment flags: 8 underline, 32 don't-commit, 64 bold.
check "an emphasis ending at Infinity covers the whole text" \
    "$emphasis" '"segments": [["xyz", 104]]'
check "initialHighlight 2 ** 31 clamps to the last candidate" \
    "$high" '"cursor": 2'
check "initialHighlight -Infinity is negative, so it suspends the highlight" \
    "$low" '"cursor": -1'
echo "Integer option checks passed."
