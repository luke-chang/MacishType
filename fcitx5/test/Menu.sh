#!/bin/sh
# Manifest menu, the daemon-side JS half: declared toggles read their
# defaults from the first evaluated statement in declaration order, a JS
# self-write acts immediately without echoing menuchange, and undeclared /
# non-boolean writes are ignored with a notice. Host-side flips (the UI
# path) are covered by MenuUi.sh; the CLI half of the same contract lives
# in jshost/tests/RunContractTests.py as a hand-written block, so this
# file is NOT parsed by that runner (its checks need key presses).
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-menu.log

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -20 >&2
        exit 1
    fi
}

# a = JS self-write (strictMode -> true), b = undeclared + non-boolean
# writes (both ignored), c = read back
ISOLATED_LOG="$log" "$root/test/Isolated.sh" menufixture a b c > /dev/null
out="$(cat "$log")"

check "declared keys read their defaults in declaration order" "$out" \
    'menufx eval keys=["strictMode","verboseHints","extraPanel"] strict=false verbose=true extra=false undeclared=undefined'
check "a JS self-write acts immediately" "$out" \
    'menufx self-write strict=true'
check "an undeclared-key write is ignored with a notice" "$out" \
    'menu: write to undeclared key ignored: notDeclared'
check "a non-boolean write is ignored with a notice" "$out" \
    'menu.strictMode: expected boolean, write ignored'
check "the ignored writes leave the value intact" "$out" \
    'menufx bad-writes strict=true'
check "the value reads back" "$out" \
    'menufx read strict=true'

count="$(grep -ac "menufx menuchange" "$log" || true)"
if [ "$count" = "0" ]; then
    echo "PASS: the JS self-write does not echo menuchange"
else
    echo "FAIL: expected no menuchange lines, saw $count" >&2
    grep -a "menufx" "$log" >&2
    exit 1
fi
echo "Menu checks passed."
