#!/bin/sh
# Engine messages (updateMessage): one line of text in place of the candidate
# list. The host draws it as an aux-only panel, keeps the candidate window
# invisible so every key still reaches the engine, and clears it when the
# composition ends or its duration runs out. jshost/tests/RunContractTests.py
# does NOT parse this file (its checks need key presses and candidate frames).
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

check_re() {
    if printf '%s\n' "$2" | grep -qE "$3"; then
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

timed_seen_line() {
    printf '%s\n' "$timed_seen" | sed -n "${1}p"
}

# KeyA (97:38) composes and shows the message; KeyE (101:26) shows one with an
# 800 ms duration; KeyF (102:41) one with a negative duration; KeyB (98:56)
# replaces it with a candidate; KeyC (99:54) retires it; KeyD (100:40) is
# unhandled and logged; Escape (65307:9) resets the context; Control+semicolon
# (59:47:4) opens fcitx5's clipboard picker. An unhandled key draws nothing,
# so the last candidate frame of a run is the last panel state the engine
# asked for.
log=/tmp/fcitx5-macishtype-message.log
shown="$(ISOLATED_LOG="$log" "$root/test/Isolated.sh" \
    messagefixture 100:40 97:38 100:40)"
seen="$(cat "$log")"
retired="$("$root/test/Isolated.sh" messagefixture 97:38 99:54)"
kept="$("$root/test/Isolated.sh" messagefixture 97:38 98:56 99:54)"
reset="$("$root/test/Isolated.sh" messagefixture 97:38 65307:9)"
focusout="$("$root/test/Isolated.sh" messagefixture 97:38 focusout)"
# The expiry run ends on the sleep: a later key would flush a pending panel
# update on its own. The other cases read the state through a trailing KeyD,
# which the engine sees whether or not the panel was redrawn; one run chains
# them, the fourth re-sending KeyE halfway through its countdown.
expired="$("$root/test/Isolated.sh" messagefixture 101:26 sleep:1500)"
# The clipboard picker draws on the same panel without the engine knowing.
picker="$("$root/test/Isolated.sh" messagefixture 101:26 59:47:4 sleep:1500)"
ISOLATED_LOG="$log" "$root/test/Isolated.sh" messagefixture \
    101:26 sleep:1500 100:40 \
    101:26 97:38 sleep:1500 100:40 \
    101:26 98:56 sleep:1500 100:40 \
    101:26 sleep:500 101:26 sleep:500 100:40 \
    102:41 sleep:1500 100:40 > /dev/null
timed_seen="$(grep 'seen KeyD' "$log")"
# With no display there is no focus group, so destroying the context sends no
# focus-out: a countdown left running would fire on a freed context and take
# fcitx5 down.
ISOLATED_LOG="$log" "$root/test/Isolated.sh" messagefixture \
    101:26 destroyic sleep:1500 > /dev/null
destroyed="$(cat "$log")"

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
check "a message with a duration shows" \
    "$expired" '"auxUp": "Short-lived"'
check "the duration running out retires the message" \
    "$(last_cand "$expired")" '"auxUp": ""'
check "the message field is null once the duration runs out" \
    "$(timed_seen_line 1)" 'message=null visible=false'
check "a new message stops the old countdown" \
    "$(timed_seen_line 2)" 'message=No match visible=false'
check "the duration running out leaves candidates alone" \
    "$(timed_seen_line 3)" 'message=null visible=true'
check "re-sending a message restarts its countdown" \
    "$(timed_seen_line 4)" 'message=Short-lived visible=false'
check "a negative duration keeps the message up" \
    "$(timed_seen_line 5)" 'message=Stays visible=false'
check_re "the duration running out leaves another module's picker alone" \
    "$(last_cand "$picker")" '"auxUp": "(剪貼簿|Clipboard)'
check "fcitx5 outlives a countdown whose context is gone" \
    "$destroyed" 'Unloading addon macishtype'
echo "Message checks passed."
