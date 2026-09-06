#!/bin/sh
# Engine messages (updateMessage): one line of text in place of the candidate
# list. The host draws it as an aux-only panel, keeps the candidate window
# invisible so every key still reaches the engine, and clears it when the
# composition ends. jshost/tests/RunContractTests.py does NOT parse this file
# (its checks need key presses and candidate frames).
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

last_cand() {
    printf '%s\n' "$1" | grep '"event": "candidates"' | tail -1
}

# KeyA (97:38) composes and shows the message; KeyB (98:56) replaces it with a
# candidate; KeyC (99:54) retires it; KeyD (100:40) is unhandled and logged;
# Escape (65307:9) resets the context. An unhandled key draws nothing, so the
# last candidate frame of a run is the last panel state the engine asked for.
log=/tmp/fcitx5-macishtype-message.log
shown="$(ISOLATED_LOG="$log" "$root/test/Isolated.sh" \
    messagefixture 100:40 97:38 100:40 2> /dev/null)"
seen="$(cat "$log")"
retired="$("$root/test/Isolated.sh" messagefixture 97:38 99:54 2> /dev/null)"
kept="$("$root/test/Isolated.sh" messagefixture 97:38 98:56 99:54 2> /dev/null)"
reset="$("$root/test/Isolated.sh" messagefixture 97:38 65307:9 2> /dev/null)"
focusout="$("$root/test/Isolated.sh" messagefixture 97:38 focusout 2> /dev/null)"

check "a message shows on the aux line" \
    "$(last_cand "$shown")" '"auxUp": "No match"'
check "a message brings no candidate list" \
    "$(last_cand "$shown")" '"items": []'
check "keys still reach the engine while a message is up" \
    "$seen" 'seen KeyD message=No match visible=false'
check "the host consumes nothing while a message is up" \
    "$shown" '"keyval": 100, "handled": false'
check "the message field is null when none is showing" \
    "$seen" 'seen KeyD message=null visible=false'
check "candidates replace a message" \
    "$(last_cand "$kept")" '"text": "甲"'
check "the aux line clears when candidates take over" \
    "$(last_cand "$kept")" '"auxUp": ""'
check "an empty message leaves candidates alone" \
    "$(last_cand "$kept")" '"items": [{'
check "an empty message retires it" \
    "$(last_cand "$retired")" '"auxUp": ""'
check "retiring leaves nothing behind" \
    "$(last_cand "$retired")" '"items": []'
check "ending the composition clears the message" \
    "$(last_cand "$reset")" '"auxUp": ""'
check "focus-out clears the message" \
    "$(last_cand "$focusout")" '"auxUp": ""'
echo "Message checks passed."
