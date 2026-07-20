#!/bin/sh
# Navigating from a suspended candidate highlight (MacishType parity): the
# first arrow/item key only reveals the first candidate without moving, while
# page keys and Home/End navigate immediately (treating suspended as index 0).
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

# navfixture: KeyA=97:38 shows c0..c8 suspended, pageSize 3 (3 pages).
# PageDown=65366:117, ArrowDown=65364:116.
paged="$("$root/test/isolated.sh" navfixture 97:38 65366:117 2> /dev/null)"
revealed="$("$root/test/isolated.sh" navfixture 97:38 65364:116 2> /dev/null)"

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -20 >&2
        exit 1
    fi
}

check_absent() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -20 >&2
        exit 1
    else
        echo "PASS: $1"
    fi
}

# Page key jumps to the next page (c3 is the first candidate of page 2).
check "a page key navigates to the next page from a suspended highlight" \
    "$paged" '"text": "c3"'
# Arrow key only reveals the first candidate: stays on page 1, no c3.
check_absent "an arrow key does not page from a suspended highlight" \
    "$revealed" '"text": "c3"'
check "an arrow key reveals the first candidate (cursor 0) from suspended" \
    "$revealed" '"text": "c2"}], "cursor": 0'
echo "Navigation checks passed."
