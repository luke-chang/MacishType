#!/bin/sh
# Intl.NumberFormat, backed by ICU. quickjs-ng ships no Intl, so the addon
# synthesizes the standard API; macOS engines get it from JavaScriptCore.
# numberfixture runs the formatter at load and logs the results. en-US
# grouping/decimal glyphs are stable across ICU versions; part shapes are
# asserted by type.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$MACISHTYPE_TEST_INSTALLED" ] || make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-number.log
ISOLATED_LOG="$log" "$root/test/Isolated.sh" numberfixture > /dev/null
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

check "grouping and fraction digits format a decimal" "$out" \
    'decimal 1,234,567.89'
check "currency style formats with symbol and grouping" "$out" \
    'currency $1,234.50'
check "percent style multiplies by 100" "$out" \
    'percent 25%'
check "BigInt keeps full precision through the decimal-string path" "$out" \
    'bigint 12,345,678,901,234,567,890'
check "minimumFractionDigits pads the fraction" "$out" \
    'minfrac 5.00'
check "useGrouping false drops the separators" "$out" \
    'nogroup 1234567'
check "signDisplay always shows a leading sign" "$out" \
    'sign +5'
check "formatToParts splits a currency amount into typed parts" "$out" \
    'currency-part-types ["currency","decimal","fraction","group","integer"]'
check "a negative value yields a minusSign part" "$out" \
    'has-minus-sign true'
check "resolvedOptions reports numbering, style, and currency" "$out" \
    'resolved latn currency USD'
check "an invalid currency code throws RangeError" "$out" \
    'invalid-currency RangeError'
check "inherited options are read like own ones" "$out" \
    'inherited-options $1.00'
check "an out-of-range option value throws RangeError at construction" "$out" \
    'invalid-option RangeError,RangeError,RangeError,RangeError,RangeError,RangeError,RangeError,RangeError'
check "each option is read once, at construction" "$out" \
    'option-reads 1 USD'
check "digit options round and range-check as ECMA-402 does" "$out" \
    'digit-options 1.2K|$1,235|¥1,234|RangeError|RangeError|TypeError'
check "useGrouping and unit follow ECMA-402" "$out" \
    'grouping-and-units 12,345|1234|12345|RangeError|50 km/h|RangeError'
check "the reported locale leaves out an options numbering system" "$out" \
    'reported-locale en-US'
echo "Intl.NumberFormat checks passed."
