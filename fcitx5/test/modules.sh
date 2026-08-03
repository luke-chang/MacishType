#!/bin/sh
# Manifest `modules`: each declared module is injected before the entry module
# evaluates, filled from <pkgdata>/macishtype/tables/<FileBase>.<language>.txt.
# Asserts the module→file mapping (a file base name, deliberately not derived
# from the module name), the per-module miss values, and the loader's comment /
# malformed-row handling. Runs in the zz test locale so only the fixture tables
# can match — never the generated zh-Hant data.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-modules.log
ISOLATED_LOG="$log" "$root/test/isolated.sh" modulesfixture sleep:600 \
    > /dev/null 2>&1

check() {
    if grep -qF "$2" "$log"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        grep -nE 'modulesfix|entries|No .* table' "$log" >&2
        exit 1
    fi
}

# Loaded counts prove the lookup used the PascalCase file base (SymbolNames,
# not the symbolNames module name) and that the skipped rows never became keys:
# SymbolNames drops a comment and a tab-less row, WordFrequency drops the row
# whose value is not a number.
check "a module's table loads from its file base name" \
    "SymbolNames.zz: 2 entries"
check "a numeric module drops rows whose value is not a number" \
    "WordFrequency.zz: 2 entries"

check "a text module answers a hit with its value" \
    "modulesfix symbolNames-hit=驚嘆號"
check "a text module answers a miss with undefined" \
    "modulesfix symbolNames-miss=undefined"
check "a commented row is not a key" \
    "modulesfix symbolNames-comment=undefined"
check "a tab-less row is not a key" \
    "modulesfix symbolNames-notab=undefined"

check "a numeric module answers a hit with its count" \
    "modulesfix wordFrequency-hit=615175"
check "a numeric module answers with a number, not a string" \
    "modulesfix wordFrequency-type=number"
check "a numeric module answers a miss with 0" \
    "modulesfix wordFrequency-miss=0"
check "a dropped non-numeric row reads as a miss" \
    "modulesfix wordFrequency-nonnumeric=0"

# fontCoverage is computed from installed fonts and has no data file at all,
# so only its shape is stable across machines.
check "a module with no data file still answers (fontCoverage)" \
    "modulesfix fontCoverage-type=boolean"

echo "Module checks passed."
