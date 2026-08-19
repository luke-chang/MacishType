#!/bin/sh
# Associated mode: committing a single character with follow-ups in the
# host dictionary (and the setting on) holds the character and offers the
# follow-ups under a "關聯字" header; picking one commits held+follow-up,
# any other key commits the held character alone.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

# assocfixture: KeyA=97:38 commits 中 (dict: 中 -> 文 國 心); digit1=49:10
# picks the first follow-up; KeyB=98:56 is an unhandled dismiss key;
# Return=65293:36 with nothing highlighted commits the held char alone.
enter="$("$root/test/isolated.sh" assocfixture 97:38 2> /dev/null)"
picked="$("$root/test/isolated.sh" assocfixture 97:38 49:10 2> /dev/null)"
dismissed="$("$root/test/isolated.sh" assocfixture 97:38 98:56 2> /dev/null)"
returned="$("$root/test/isolated.sh" assocfixture 97:38 65293:36 2> /dev/null)"

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

# The associated candidate list carries the header and the dictionary's
# follow-ups; it is the event whose auxUp is 關聯字.
assoc_line="$(printf '%s\n' "$enter" | grep -F '"auxUp": "關聯字"')"
check "committing a single char enters associated mode with a header" \
    "$assoc_line" '"auxUp": "關聯字"'
check "associated candidates come from the host dictionary" \
    "$assoc_line" '"text": "文"'
check "picking a follow-up commits held + follow-up" \
    "$picked" '{"event": "commit", "text": "中文"}'
check "an unhandled key dismisses, committing the held char alone" \
    "$dismissed" '{"event": "commit", "text": "中"}'
# With no follow-up highlighted yet, Return commits the held char, not the
# first follow-up.
check "Return with nothing highlighted commits the held char alone" \
    "$returned" '{"event": "commit", "text": "中"}'

# --- Staged prefix retention through the fallback ---
# stagedassocfixture: KeyA stages 甲 (of 甲乙) and offers the one-char
# candidate 中. Confirming 中 must fold the staged prefix into the held
# text (甲中) and enter associated mode off 中's follow-ups — not commit,
# and not drop 甲. A second Return (nothing highlighted) flushes the
# accumulated held text.
staged="$("$root/test/isolated.sh" stagedassocfixture 97:38 65293:36 2> /dev/null)"
stagedout="$("$root/test/isolated.sh" stagedassocfixture 97:38 65293:36 65293:36 2> /dev/null)"

check "confirming with a staged prefix enters associated mode" \
    "$staged" '"auxUp": "關聯字"'
check "the staged prefix folds into the held text" \
    "$staged" '"text": "甲中", "cursor"'
check_absent "confirming with a staged prefix does not commit yet" \
    "$staged" '"event": "commit"'
check "Return then flushes the accumulated held text" \
    "$stagedout" '{"event": "commit", "text": "甲中"}'

# --- Chained associated input ---
# Each pick re-enters associated mode with the accumulated text; the chain
# ends (committing everything) when the next round has no follow-ups.
# hostchainfixture omits the candidates argument, so the host keys each
# round off the held text's LAST character (存 → 錢 → 包, no 包 entry);
# chainfixture supplies its own lists, ending with an explicit empty array.
hostchain="$("$root/test/isolated.sh" hostchainfixture 97:38 49:10 49:10 2> /dev/null)"
enginechain="$("$root/test/isolated.sh" chainfixture 97:38 49:10 49:10 2> /dev/null)"

check "the dictionary chains off the held text's last character" \
    "$hostchain" '"text": "包"'
check "a dictionary miss ends the chain, committing the accumulated text" \
    "$hostchain" '{"event": "commit", "text": "存錢包"}'
check "an engine-supplied empty candidates array ends the chain" \
    "$enginechain" '{"event": "commit", "text": "存錢包"}'

# --- Grapheme-cluster dictionary keying ---
# graphemefixture KeyB=98:56 holds 存⚙︎; the gear ends in U+FE0E, so a
# last-code-point key would miss — the dictionary key is the full trailing
# cluster. digit1=49:10 picks the follow-up. The gear is built from explicit
# bytes: editors silently normalize variation sequences.
gear="$(printf '\342\232\231\357\270\216')"
cluster_held="$("$root/test/isolated.sh" graphemefixture 98:56 2> /dev/null)"
cluster_out="$("$root/test/isolated.sh" graphemefixture 98:56 49:10 2> /dev/null)"

check "a multi-code-point trailing cluster keys the dictionary" \
    "$cluster_held" '"auxUp": "關聯字"'
check "its follow-ups come from the full-cluster entry" \
    "$cluster_held" '"text": "齒"'
check "picking a follow-up commits the held text plus the follow-up" \
    "$cluster_out" "{\"event\": \"commit\", \"text\": \"存${gear}齒\"}"
echo "Associated-mode checks passed."
