#!/bin/sh
# event.beep() end to end: KeyA beeps once, KeyZ calls it three times inside
# one hook and only one sound comes out. The collapsing itself lives in the
# shared hostglue and is pinned by jshost/tests/RunContractTests.py; this
# file checks that the fcitx5 side plays exactly what arrives. The
# assertions count log lines rather than match one marker, so
# RunContractTests.py does NOT parse this file.
#
# The run picks the None cue so the suite stays quiet; the counted log line
# is written before the request reaches AlertSound, so nothing is lost.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$MACISHTYPE_TEST_INSTALLED" ] || make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-beep.log

beeps() {
    ISOLATED_LOG="$log" "$root/test/Isolated.sh" beepfixture \
        setaddonopt:macishtype:AlertSound=none "$1" > /dev/null
}

check() {
    if eval "$2"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        tail -20 "$log" >&2
        exit 1
    fi
}

beeps 97:38
check "one beep() call plays one sound" \
    "[ \$(grep -cF 'beepfixture: beep' '$log') -eq 1 ]"

beeps 122:52
check "three beep() calls in one event collapse into one sound" \
    "[ \$(grep -cF 'beepfixture: beep' '$log') -eq 1 ]"

echo "beep checks passed."
