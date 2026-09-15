#!/bin/sh
# The outputToSimplified capability backs manifest.toggle with chttrans:
# available on Traditional-Chinese engines from the first evaluated
# statement, a JS write flips chttrans without echoing togglechange, and a
# user flip (the chttrans hotkey, Control+Shift+F) reaches the engine as
# togglechange. capability false removes the surface entirely, and a
# malformed capability flag is warned about and treated as undeclared.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

onlog=/tmp/fcitx5-macishtype-toggle-on.log
offlog=/tmp/fcitx5-macishtype-toggle-off.log

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -20 >&2
        exit 1
    fi
}

# a = JS self-write (-> true), 70:41:5 = Control+Shift+F pressed by the
# user (chttrans's toggle hotkey, -> false), b = read back; then a config
# write that bypasses the toggle action (the configtool path, -> true)
# followed by a refocus, whose activate boundary must reconcile it.
ISOLATED_LOG="$onlog" "$root/test/Isolated.sh" togglefixture \
    a "70:41:5" b \
    "setaddonconfig:chttrans:EnabledIM=macishtype-togglefixture" \
    refocus > /dev/null
out="$(cat "$onlog")"

# Positive control: the negative "does not pull in chttrans" greps below
# are only meaningful while this exact core log line exists.
check "the capable engine pulls in chttrans" "$out" \
    'Loaded addon chttrans'
check "the toggle exists (and reads false) from the first evaluated statement" \
    "$out" 'togglefx eval value=false keys=["outputToSimplified"]'
check "a JS write acts immediately" "$out" \
    'togglefx self-write value=true'
check "the user hotkey flip reaches the engine as togglechange" "$out" \
    'togglefx togglechange key=outputToSimplified value=false'
check "the flipped value reads back" "$out" \
    'togglefx read value=false'
check "a config write that bypasses the action reconciles at activate" \
    "$out" 'togglefx togglechange key=outputToSimplified value=true'

count="$(grep -ac "togglefx togglechange" "$onlog" || true)"
if [ "$count" = "2" ]; then
    echo "PASS: the JS self-write does not echo togglechange"
else
    echo "FAIL: expected exactly two togglechange lines, saw $count" >&2
    grep -a "togglefx" "$onlog" >&2
    exit 1
fi

selfwrite_line="$(grep -an "togglefx self-write" "$onlog" | head -1 | cut -d: -f1)"
change_line="$(grep -an "togglefx togglechange" "$onlog" | head -1 | cut -d: -f1)"
if [ -n "$selfwrite_line" ] && [ -n "$change_line" ] &&
    [ "$selfwrite_line" -lt "$change_line" ]; then
    echo "PASS: togglechange follows the self-write (hotkey flip, not echo)"
else
    echo "FAIL: unexpected order (self-write at $selfwrite_line, togglechange at $change_line)" >&2
    exit 1
fi

ISOLATED_LOG="$offlog" "$root/test/Isolated.sh" toggleofffixture a > /dev/null
out="$(cat "$offlog")"

check "capability false removes the manifest.toggle key" "$out" \
    'toggleofffx eval value=undefined keys=[]'
check "a write to the unavailable key is ignored" "$out" \
    'toggleofffx write-after value=undefined'
check "the ignored write is warned about" "$out" \
    'toggle: write to unavailable key ignored'
check "a malformed capability flag is warned about" "$out" \
    'capabilities.fullwidthInput must be a boolean'

if grep -qa "Loaded addon chttrans" "$offlog"; then
    echo "FAIL: chttrans loaded for a capability-false engine" >&2
    exit 1
else
    echo "PASS: capability false does not pull in chttrans"
fi
if grep -qa "Loaded addon fullwidth" "$offlog"; then
    echo "FAIL: fullwidth loaded despite the malformed capability flag" >&2
    exit 1
else
    echo "PASS: the malformed fullwidthInput does not pull in fullwidth"
fi
echo "Toggle-capability checks passed."
