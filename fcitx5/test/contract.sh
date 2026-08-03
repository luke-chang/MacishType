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
    "$root/test/isolated.sh" contractfixture > /dev/null 2>&1
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
check "a non-ASCII indexLabels write is rejected, keeping the prior value" \
    "$out" 'indexlabels-after-bad 12345'
check "pageSize 11 is accepted" "$out" \
    'pagesize-boundary 11'
check "a pageSize above 11 is rejected, keeping the prior value" "$out" \
    'pagesize-after-bad 11'
check "outputToSimplified stays unavailable without a Traditional-Chinese language" \
    "$out" 'toggle-nonchinese value=undefined keys=[]'
check "dynamic import() of an already-loaded module is rejected" "$out" \
    'dynamic-import-loaded rejected dynamic import() is not supported'
check "dynamic import() of a loadable module is rejected" "$out" \
    'dynamic-import-fresh rejected dynamic import() is not supported'
echo "Contract conformance checks passed."
