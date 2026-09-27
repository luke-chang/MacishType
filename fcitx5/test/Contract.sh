#!/bin/sh
# Small contract conformance fixes, each exercised at load by contractfixture
# and asserted here. Locale is pinned via LANGUAGE (LC_*/LANG set to C so
# preferredLanguages ignores them) to keep the language checks deterministic
# across machines.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-contract.log
LANGUAGE="zh_TW:en_US" LANG=C LC_ALL=C LC_MESSAGES=C ISOLATED_LOG="$log" \
    "$root/test/Isolated.sh" contractfixture > /dev/null
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

check "navigator.languages carries the region->base fallback chain" "$out" \
    'nav-languages ["zh-TW","zh","en-US","en"]'
check "a name map with no match falls back to the lowest-sorted key" "$out" \
    'manifest-name AA'
check "an engine-root-absolute import resolves from the engine folder" "$out" \
    'root-import root-import-ok'
check "localStorage.key(index) reports keys alphabetically" "$out" \
    'key-order apple,mango,zebra'
check "an unpaired surrogate reaches the host as U+FFFD" "$out" \
    'lone-surrogate a�b'
check "per-implementation candidateWindow fields never reach the proxy" "$out" \
    'cw-impl expandable=undefined moveOnExpand=undefined macish=undefined fontSize=20 keys=["fontSize"]'
check "a non-ASCII indexLabels write is rejected, keeping the prior value" "$out" \
    'indexlabels-after-bad 12345'
check "pageSize 11 is accepted" "$out" \
    'pagesize-boundary 11'
check "a pageSize above 11 is rejected, keeping the prior value" "$out" \
    'pagesize-after-bad 11'
check "a fractional or NaN pageSize is rejected, keeping the prior value" "$out" \
    'pagesize-after-fraction 11'
check "a fontSize below 8 or fractional is rejected, keeping the prior value" "$out" \
    'fontsize-after-bad 20'
check "indexLabelDigitsRequireShift is writable and reads back" "$out" \
    'requireshift-write true'
check "an out-of-vocabulary associatedModeIndexLabels write is rejected" "$out" \
    'assocmode-after-bad shiftNumbers'
check "an omitted Intl locale resolves to the preferred language" "$out" \
    'intl-default zh-TW zh-TW'
check "a requested locale ICU has no data for is skipped" "$out" \
    'intl-lookup de'
check "legacy language codes still reach the data ICU aliases them to" "$out" \
    'intl-legacy he tl'
check "null Intl locales and options, and primitive Segmenter options, throw TypeError" "$out" \
    'intl-null TypeError,TypeError,TypeError,TypeError,TypeError,TypeError'
check "malformed locale lists throw as ECMA-402 requires" "$out" \
    'intl-lists RangeError,TypeError,RangeError,RangeError zh-TW'
check "toLocaleUpperCase and toLocaleLowerCase follow the requested language" "$out" \
    'intl-case İ ı I I RangeError'
check "localeCompare and toLocale*String go through Intl" "$out" \
    'intl-builtins -1 -1 1.234.567,5 2026/9/27'
check "Date defaults are added over a frozen options object" "$out" \
    'intl-frozen 1/1/1970'
check "outputToSimplified stays unavailable without a Traditional-Chinese language" "$out" \
    'toggle-nonchinese value=undefined keys=[]'
check "dynamic import() of an already-loaded module is rejected" "$out" \
    'dynamic-import-loaded rejected dynamic import() is not supported'
check "dynamic import() of a loadable module is rejected" "$out" \
    'dynamic-import-fresh rejected dynamic import() is not supported'
echo "Contract conformance checks passed."
