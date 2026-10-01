#!/bin/sh
# A JS engine that throws must log the error's stack trace, not just its
# message — a module top-level throw surfaces as a rejected module promise,
# and the rejection reason has to be rendered with its `.stack`. throwfixture
# throws from a named function at load; the isolated log should carry the
# frames.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$MACISHTYPE_TEST_INSTALLED" ] || make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-errorstack.log
ISOLATED_LOG="$log" "$root/test/Isolated.sh" throwfixture > /dev/null
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

check "the rejection message reaches the log" "$out" \
    'Entry module rejected: Error: boom from engine'
check "the rejection carries the throwing frame" "$out" \
    'at inner (engine:///index.js'
check "the rejection carries the module frame" "$out" \
    'at <anonymous> (engine:///index.js'
echo "JS error-stack checks passed."
