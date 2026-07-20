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
echo "Associated-mode checks passed."
