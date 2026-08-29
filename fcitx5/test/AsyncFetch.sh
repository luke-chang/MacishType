#!/bin/sh
# Deferred fetch: the engine module finishes loading before its fetched
# table is read+parsed (the read runs on a worker thread once a session is
# active), and an entry module that top-level-awaits a fetch still loads via
# the synchronous fallback. The discriminating assertion is log ORDER —
# "Engine loaded" precedes the parsed marker only when the fetch is
# deferred — so the test is timing-free.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

line_of() {
    grep -nF "$2" "$1" | head -1 | cut -d: -f1
}

# --- Deferred pipeline: usable engine first, table parsed in the background.
log=/tmp/fcitx5-macishtype-asyncfetch.log
output="$(ISOLATED_LOG="$log" "$root/test/Isolated.sh" asyncfetchfixture \
    97:38 sleep:1200 2> /dev/null)"

loaded_line="$(line_of "$log" 'Engine loaded: asyncfetchfixture')"
parsed_line="$(line_of "$log" 'asyncfetch parsed entries=3')"

if [ -n "$parsed_line" ]; then
    echo "PASS: the table parse completes in the background"
else
    echo "FAIL: the table parse completes in the background" >&2
    tail -20 "$log" >&2
    exit 1
fi

if [ -n "$loaded_line" ] && [ "$loaded_line" -lt "$parsed_line" ]; then
    echo "PASS: the engine finishes loading before the parse (deferred fetch)"
else
    echo "FAIL: the engine finishes loading before the parse" >&2
    grep -nE 'Engine loaded|asyncfetch' "$log" >&2
    exit 1
fi

if grep -qF 'asyncfetch nul-text Error msg=Body is not valid UTF-8' "$log"; then
    echo "PASS: text() rejects invalid UTF-8 after an embedded NUL"
else
    echo "FAIL: text() rejects invalid UTF-8 after an embedded NUL" >&2
    grep -nF 'asyncfetch' "$log" >&2
    exit 1
fi

if printf '%s\n' "$output" | grep -qF '"event": "commit"'; then
    echo "PASS: a key handled during the load window still commits"
else
    echo "FAIL: a key handled during the load window still commits" >&2
    printf '%s\n' "$output" >&2
    exit 1
fi

# --- Top-level await: the synchronous fallback keeps such engines loading.
tla_log=/tmp/fcitx5-macishtype-asyncfetch-tla.log
ISOLATED_LOG="$tla_log" "$root/test/Isolated.sh" tlafixture sleep:500 \
    > /dev/null 2>&1

tla_line="$(line_of "$tla_log" 'tla loaded entries=3')"
tla_loaded_line="$(line_of "$tla_log" 'Engine loaded: tlafixture')"

if [ -n "$tla_loaded_line" ]; then
    echo "PASS: a top-level-await engine still loads"
else
    echo "FAIL: a top-level-await engine still loads" >&2
    tail -20 "$tla_log" >&2
    exit 1
fi

if [ -n "$tla_line" ] && [ "$tla_line" -lt "$tla_loaded_line" ]; then
    echo "PASS: its awaited fetch settles during load (synchronous fallback)"
else
    echo "FAIL: its awaited fetch settles during load" >&2
    grep -nE 'Engine loaded|tla ' "$tla_log" >&2
    exit 1
fi
echo "Async-fetch checks passed."
