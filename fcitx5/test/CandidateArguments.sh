#!/bin/sh
# Candidate mutator arguments off their declared types. A candidate item or
# commit argument that is not an object is the display text, and an object's
# candidate and annotation read like any text argument: undefined and null as
# empty, everything else stringified. commitCandidateAtIndex without a finite
# number is a no-op. Per-update window options take the manifest's ranges,
# and a value outside them is ignored. jshost/tests/RunContractTests.py does
# NOT parse this file (the decoding lives in the fcitx5 session).
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

check_absent() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -20 >&2
        exit 1
    else
        echo "PASS: $1"
    fi
}

last_cand() {
    printf '%s\n' "$1" | grep '"event": "candidates"' | tail -1
}

# Keysym:keycode pairs for KeyA through KeyJ; see the fixture for what each
# key sends.
items="$("$root/test/Isolated.sh" candargfixture 97:38)"
listed="$(last_cand "$items")"
committed="$("$root/test/Isolated.sh" candargfixture 98:56)"
indexed="$("$root/test/Isolated.sh" candargfixture 99:54 100:40 101:26)"
big_page="$(last_cand "$("$root/test/Isolated.sh" candargfixture 102:41)")"
fraction_page="$(last_cand "$("$root/test/Isolated.sh" candargfixture 103:42)")"
direction="$(last_cand "$("$root/test/Isolated.sh" candargfixture 104:43)")"
labels="$(last_cand "$("$root/test/Isolated.sh" candargfixture 105:31)")"
valid="$(last_cand "$("$root/test/Isolated.sh" candargfixture 106:44)")"

check "a number item shows as its text" \
    "$listed" '"label": "a ", "text": "42"'
check "a null item shows as an empty candidate" \
    "$listed" '"label": "b ", "text": ""'
check_absent "a null item never shows as a word" \
    "$items" '"text": "null"'
check "an object's number candidate and annotation stringify" \
    "$listed" '"label": "c ", "text": "7 8"'
check "commit(42) commits the number's text" \
    "$committed" '"event": "commit", "text": "42"'
check_absent "no commitCandidateAtIndex without a number picks the first" \
    "$indexed" '"event": "commit", "text": "甲"'
check "the window survives them, so index 1 still commits" \
    "$indexed" '"event": "commit", "text": "乙"'
check "a pageSize above 11 leaves the manifest's three per page" \
    "$big_page" '"label": "c ", "text": "三"'
check_absent "so the fourth candidate is not on the first page" \
    "$big_page" '"text": "四"'
check "a fractional pageSize is ignored rather than truncated" \
    "$fraction_page" '"label": "c ", "text": "三"'
# Layout hint ints: 1 = vertical, 2 = horizontal (fcitx CandidateLayoutHint).
check "an unknown layoutDirection leaves the manifest's vertical" \
    "$direction" '"layout": 1'
check "non-ASCII indexLabels leave the manifest's labels" \
    "$labels" '"label": "a ", "text": "一"'
check "valid overrides still apply: the page size" \
    "$valid" '"label": "y ", "text": "二"'
check_absent "valid overrides still apply: no third candidate on the page" \
    "$valid" '"text": "三"'
check "valid overrides still apply: the layout" \
    "$valid" '"layout": 2'
echo "Candidate argument checks passed."
