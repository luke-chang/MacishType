#!/bin/sh
# Intl.Segmenter (grapheme, word, sentence). quickjs-ng ships no Intl, so the
# addon synthesizes the standard API over ICU's UAX #29 break iterators;
# macOS engines get the same API from JavaScriptCore. segmenterfixture runs
# the segmenter at load and logs the results.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-segmenter.log
ISOLATED_LOG="$log" "$root/test/Isolated.sh" segmenterfixture > /dev/null 2>&1
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

# Clustering: combining mark, astral codepoint, emoji ZWJ sequence, flag
# (regional-indicator pair), and conjoining Hangul jamo each count as one.
check "grapheme counts follow UAX #29 clustering" "$out" \
    'grapheme-counts {"ascii":3,"combining":1,"astral":1,"zwj":1,"flag":1,"hangulJamo":1,"mixed":3}'
check "segment indices are UTF-16 code-unit offsets" "$out" \
    'grapheme-indices [0,2,3]'
check "containing() finds the segment covering an interior offset" "$out" \
    'containing-index 0'
check "word granularity segments and flags word-like runs" "$out" \
    'word-like ["The","quick","fox"]'
check "sentence granularity splits into sentences" "$out" \
    'sentence-count 2'
check "sentence segments reconstruct the input" "$out" \
    'sentence-rejoin true'
check "an unknown granularity throws RangeError" "$out" \
    'bad-granularity RangeError'
check "resolvedOptions reports the locale and granularity" "$out" \
    'resolved {"locale":"zh-Hant","granularity":"grapheme"}'
echo "Intl.Segmenter checks passed."
