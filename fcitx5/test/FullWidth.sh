#!/bin/sh
# The `fullwidthInput` capability is the portable stand-in for macOS's
# Option+key full-width trigger: on fcitx5 the host puts fcitx's full-width
# toggle in the engine's status area. Declaring it must pull in fcitx's
# (OnDemand) fullwidth module on activate; a plain engine must not.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$MACISHTYPE_TEST_INSTALLED" ] || make -s -C "$root" dev-install > /dev/null

poslog=/tmp/fcitx5-macishtype-fullwidth-pos.log
neglog=/tmp/fcitx5-macishtype-fullwidth-neg.log
ISOLATED_LOG="$poslog" "$root/test/Isolated.sh" fullwidthfixture > /dev/null
ISOLATED_LOG="$neglog" "$root/test/Isolated.sh" segmenterfixture > /dev/null

if grep -qa "Loaded addon fullwidth" "$poslog"; then
    echo "PASS: declaring fullwidthInput pulls in fcitx's fullwidth module"
else
    echo "FAIL: fullwidth module was not loaded for a capable engine" >&2
    tail -20 "$poslog" >&2
    exit 1
fi

if grep -qa "Loaded addon fullwidth" "$neglog"; then
    echo "FAIL: fullwidth module loaded for an engine that did not ask" >&2
    exit 1
else
    echo "PASS: a plain engine does not pull in the fullwidth module"
fi
echo "Fullwidth-capability checks passed."
