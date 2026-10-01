#!/bin/sh
# Mutator text arguments that are not strings. undefined and null read as
# "not given" — an empty string, which clears marked text and retires a
# message — and every other type stringifies, the same reading JavaScript
# gives a string parameter anywhere else. The follow-up list's elements take
# the same rule. jshost/tests/RunContractTests.py does NOT parse this file
# (the decoding lives in the fcitx5 session).
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$MACISHTYPE_TEST_INSTALLED" ] || make -s -C "$root" dev-install > /dev/null

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

last_preedit() {
    printf '%s\n' "$1" | grep '"event": "preedit"' | tail -1
}

# KeyA (97:38) composes, KeyB (98:56) clears it with undefined, KeyH (104:43)
# stages a prefix and flushes a number after it. KeyC (99:54) puts a message
# up for KeyD (100:40) to retire with null. KeyE (101:26) holds an undefined
# text. KeyF (102:41) sends a number as a message, then KeyG (103:42) hands
# the follow-up list an undefined element.
cleared="$("$root/test/Isolated.sh" textargfixture 97:38 98:56 104:43)"
retired="$("$root/test/Isolated.sh" textargfixture 99:54 100:40)"
held_log=/tmp/fcitx5-macishtype-textargs-held.log
held="$(ISOLATED_LOG="$held_log" "$root/test/Isolated.sh" textargfixture 101:26)"
held_seen="$(cat "$held_log")"
listed="$("$root/test/Isolated.sh" textargfixture 102:41 103:42)"

check "undefined clears the marked text" \
    "$cleared" '"text": "", "cursor": 0'
check_absent "undefined never reaches the client as a word" \
    "$cleared" '"text": "undefined"'
check "a number flushes after the staged prefix" \
    "$cleared" '"event": "commit", "text": "x42"'
check "the message this run retires is really up first" \
    "$retired" '"auxUp": "No match"'
check "null retires that message" \
    "$(last_cand "$retired")" '"auxUp": ""'
check_absent "null never reaches the aux line as a word" \
    "$retired" '"auxUp": "null"'
check "an undefined held text takes the empty-held-text exit" \
    "$held_seen" 'textargfixture: enterAssociatedMode with an empty held text: 1 follow-ups dropped, composition ended'
check_absent "an undefined held text opens no window" \
    "$held" '"text": "甲"'
check_absent "an undefined held text is never held literally" \
    "$held" '"text": "undefined"'
check "a number shows on the message line as its text" \
    "$listed" '"auxUp": "42"'
check "the follow-ups still carry the element that was a string" \
    "$(last_cand "$listed")" '"text": "甲"'
check_absent "an undefined follow-up is never listed as a word" \
    "$listed" '"text": "undefined"'
echo "Text argument checks passed."
