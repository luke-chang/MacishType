#!/bin/sh
# Grapheme cluster indexing: character indices in updateMarkedText (staged /
# cursor / emphasis) count extended grapheme clusters, so multi-code-point
# clusters (variation sequences, combining marks, emoji ZWJ) are never split
# across preedit segments and the caret byte offset lands on a cluster
# boundary.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$MACISHTYPE_TEST_INSTALLED" ] || make -s -C "$root" dev-install > /dev/null

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" >&2
        exit 1
    fi
}

check_absent() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" >&2
        exit 1
    else
        echo "PASS: $1"
    fi
}

# Assertion strings are built from explicit byte sequences: editors would
# silently normalize the combining mark (e U+0301) and the variation
# sequence (U+2699 U+FE0E) to other forms.
gear="$(printf '\342\232\231\357\270\216')"                          # U+2699 U+FE0E
eacute="$(printf 'e\314\201')"                                       # e U+0301
woman_laptop="$(printf '\360\237\221\251\342\200\215\360\237\222\273')" # U+1F469 U+200D U+1F4BB

# graphemefixture KeyA=97:38 emits "⚙︎é👩‍💻x" (cluster byte boundaries
# 0/6/9/20/21) with staged 1, cursor 2, emphasis {1,3} — cuts at clusters
# 0/1/3/4 give segments ⚙︎ | é👩‍💻 | x and a caret at byte 9.
out="$("$root/test/Isolated.sh" graphemefixture 97:38)"
preedit="$(printf '%s\n' "$out" | grep '"event": "preedit"' | tail -1)"

check "the full marked text renders" \
    "$preedit" "\"text\": \"${gear}${eacute}${woman_laptop}x\""
check "the staged cut keeps the variation sequence whole" \
    "$preedit" "[\"${gear}\", "
check_absent "no segment splits the variation sequence" \
    "$preedit" '["⚙", '
check "the emphasis range spans whole clusters" \
    "$preedit" "[\"${eacute}${woman_laptop}\", "
check "the post-emphasis segment starts on a cluster boundary" \
    "$preedit" '["x", '
check "the cursor lands on the cluster-2 byte offset" \
    "$preedit" '"cursor": 9'

echo "Grapheme-boundary checks passed."
