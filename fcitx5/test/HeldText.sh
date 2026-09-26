#!/bin/sh
# enterAssociatedMode with an empty held text. The held text is what keeps a
# composition under the follow-ups, so the host ends the composition, commits
# nothing, drops any supplied follow-ups with a notice, and never enters
# associated mode. jshost/tests/RunContractTests.py does NOT parse this file
# (the behavior lives in the fcitx5 session, not in jshost).
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

# KeyA (97:38) asks for associated mode with no held text, KeyZ (122:52)
# reports the session state through the engine log, Escape (65307:9) shows
# the associated tier is not holding the keys. KeyB (98:56) asks with no
# follow-ups either. Each run needs its own log: Isolated.sh truncates the
# one path it is given.
supplied_log=/tmp/fcitx5-macishtype-heldtext-supplied.log
supplied="$(ISOLATED_LOG="$supplied_log" "$root/test/Isolated.sh" \
    heldtextfixture 97:38 122:52 65307:9)"
supplied_seen="$(cat "$supplied_log")"

bare_log=/tmp/fcitx5-macishtype-heldtext-bare.log
bare="$(ISOLATED_LOG="$bare_log" "$root/test/Isolated.sh" \
    heldtextfixture 98:56 122:52)"
bare_seen="$(cat "$bare_log")"

check "the key is still handled" \
    "$supplied" '"keyval": 97, "handled": true'
check "the dropped follow-ups are reported" \
    "$supplied_seen" 'heldtextfixture: enterAssociatedMode with an empty held text: 2 follow-ups dropped, composition ended'
check_absent "no candidate window opens" \
    "$supplied" '"text": "甲"'
check_absent "nothing is committed" \
    "$supplied" '"event": "commit"'
check "the session is left idle, not associating" \
    "$supplied_seen" 'seen KeyZ associating=false visible=false'
check "Escape is not eaten by the associated tier" \
    "$supplied" '"keyval": 65307, "handled": false'
check_absent "nothing to drop reports nothing" \
    "$bare_seen" 'follow-ups dropped'
check_absent "an empty request commits nothing" \
    "$bare" '"event": "commit"'
check "an empty request also leaves the session idle" \
    "$bare_seen" 'seen KeyZ associating=false'
echo "Held text checks passed."
