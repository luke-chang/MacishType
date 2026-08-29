#!/bin/sh
# Intl.PluralRules, backed by ICU. quickjs-ng ships no Intl, so the addon
# synthesizes the standard API; macOS engines get it from JavaScriptCore.
# pluralfixture selects categories at load and logs the results. Category
# names are stable CLDR keywords, so they are asserted exactly.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-plural.log
ISOLATED_LOG="$log" "$root/test/Isolated.sh" pluralfixture > /dev/null 2>&1
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

check "English cardinal selects one and other" "$out" \
    'en-cardinal other one other'
check "English ordinal selects one/two/few/other" "$out" \
    'en-ordinal one two few other'
check "fraction digits reshape the operands" "$out" \
    'frac-affects other'
check "a richer locale exercises few and many" "$out" \
    'pl-cardinal few many'
check "resolvedOptions lists the locale's categories" "$out" \
    'categories ["one","other"]'
check "resolvedOptions reports the plural type" "$out" \
    'resolved-type ordinal'
check "an unknown type throws RangeError" "$out" \
    'invalid-type RangeError'
echo "Intl.PluralRules checks passed."
