#!/bin/sh
# Intl.DateTimeFormat, backed by ICU. quickjs-ng ships no Intl, so the addon
# synthesizes the standard API; macOS engines get it from JavaScriptCore.
# datetimefixture runs the formatter at load and logs the results. Assertions
# target structure and types, not localized glyphs, so they hold across ICU
# versions.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-datetime.log
ISOLATED_LOG="$log" "$root/test/Isolated.sh" datetimefixture > /dev/null 2>&1
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

check "resolvedOptions reports the calendar" "$out" \
    'resolved-calendar gregory'
check "resolvedOptions reports the numbering system" "$out" \
    'resolved-numbering latn'
check "resolvedOptions reports the system IANA time zone" "$out" \
    'resolved-timezone-nonempty true'
check "the constructor works without new" "$out" \
    'no-new-timezone-nonempty true'
check "formatToParts emits typed date and time-zone parts" "$out" \
    'parts-types ["day","literal","month","timeZoneName","year"]'
check "a fixed epoch with an explicit zone formats deterministically" "$out" \
    'format-24h 07:00'
check "hour12 false resolves to a 24-hour cycle" "$out" \
    'resolved-hourcycle-24 h23'
check "hour12 false is reported in resolvedOptions" "$out" \
    'resolved-hour12-24 false'
check "hour12 true produces an AM/PM marker" "$out" \
    'format-12h-has-ampm true'
check "hour12 true resolves to a 12-hour cycle" "$out" \
    'resolved-hourcycle-12 h12'
check "dateStyle presets format without throwing" "$out" \
    'style-nonempty true'
check "mixing a style with a component option throws TypeError" "$out" \
    'style-component-mix TypeError'
check "an invalid time zone throws RangeError" "$out" \
    'invalid-tz RangeError'
check "the timezone macro finds a generic time-zone name" "$out" \
    'tzname-longgeneric-found true'
echo "Intl.DateTimeFormat checks passed."
