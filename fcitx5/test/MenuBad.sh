#!/bin/sh
# Manifest menu validation: every broken item drops with a notice, the
# surviving toggle keeps the first declaration's default. All assertions
# are load-time log lines, so jshost/tests/RunContractTests.py parses this
# file's checks and asserts them against the headless CLI too.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-menubad.log
ISOLATED_LOG="$log" "$root/test/Isolated.sh" menubadfixture > /dev/null
out="$(cat "$log")"

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -20 >&2
        exit 1
    fi
}

check "the surviving toggle keeps the first declaration's default" "$out" \
    'menubadfx eval keys=["good","nullCondition"] good=false'
check "a JSON-null condition counts as absent, not broken" "$out" \
    'keys=["good","nullCondition"]'
check "a reserved settings. key is dropped" "$out" \
    'dropped (key prefix `settings.` is reserved)'
check "a duplicate key keeps the first declaration" "$out" \
    'dropped (duplicate key: good)'
check "a toggle missing label or default is dropped" "$out" \
    'dropped (toggle requires key, label, and a boolean default)'
check "an unknown item type is dropped" "$out" \
    'dropped (unknown menu item type: widget)'
check "an item without a type is dropped" "$out" \
    'dropped (missing type)'
check "a malformed condition drops its item" "$out" \
    'dropped (invalid condition)'
check "a non-object item is dropped" "$out" \
    'dropped (not an object)'
echo "MenuBad checks passed."
