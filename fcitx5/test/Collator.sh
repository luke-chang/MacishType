#!/bin/sh
# Intl.Collator, backed by ICU. quickjs-ng ships no Intl, so the addon
# synthesizes the standard API; macOS engines get it from JavaScriptCore.
# collatorfixture compares strings at load and logs the results by sign, which
# is stable across ICU versions.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$MACISHTYPE_TEST_INSTALLED" ] || make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-collator.log
ISOLATED_LOG="$log" "$root/test/Isolated.sh" collatorfixture > /dev/null
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

check "base sensitivity ignores case" "$out" \
    'base-case-equal 0'
check "base sensitivity ignores accents" "$out" \
    'base-accent-equal 0'
check "accent sensitivity distinguishes accented letters" "$out" \
    'accent-distinguishes true'
check "numeric collation orders 10 after 9" "$out" \
    'numeric-order 1'
check "plain collation orders 10 before 9" "$out" \
    'plain-order -1'
check "caseFirst upper sorts capitals first" "$out" \
    'casefirst-upper -1'
check "compare is a valid Array#sort comparator" "$out" \
    'sorted ["Apple","banana","cherry"]'
check "resolvedOptions echoes sensitivity, numeric, and usage" "$out" \
    'resolved accent true sort'
check "an unknown sensitivity throws RangeError" "$out" \
    'invalid-sensitivity RangeError'
echo "Intl.Collator checks passed."
