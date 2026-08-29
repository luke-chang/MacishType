#!/bin/sh
# getModifierState reports the lock states a host can see, not just the held
# modifiers. NumLock is the host-dependent one, so a key carrying Mod2 must
# surface as true. Keys arrive through the DBus frontend here, which covers
# the translate -> session -> JS path; whether Mod2 reaches the addon in a
# real session is separate (it does not in a GNOME Wayland one).
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-modifier.log

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -20 >&2
        exit 1
    fi
}

# a=97:38, A=65:38, b=98:56, c=99:54. The third field is a fcitx KeyStates
# bitmask: 16 = NumLock (Mod2), 17 = NumLock + Shift, 128 = Mod5, 32 = Mod3.
# What those last two carry is layout-dependent — AltGr and level-5 shift in
# the common maps; fcitx names Mod3 Hyper.
ISOLATED_LOG="$log" "$root/test/Isolated.sh" modifierfixture \
    "97:38" "97:38:16" "65:38:17" "98:56:128" "99:54:32" > /dev/null 2>&1
out="$(cat "$log")"

check "a key with no modifiers reports every state off" "$out" \
    'modifierfx KeyA states=[]'
check "NumLock reaches the engine as a live state" "$out" \
    'modifierfx KeyA states=[NumLock]'
check "NumLock composes with a held modifier" "$out" \
    'modifierfx KeyA states=[Shift,NumLock]'
# The contract says AltGraph / Hyper / ScrollLock / Fn are false on every
# host; these two pin that down and catch a stray mapping onto Alt or Meta.
check "an AltGr-level modifier surfaces no state" "$out" \
    'modifierfx KeyB states=[]'
check "a Hyper-level modifier surfaces no state" "$out" \
    'modifierfx KeyC states=[]'
echo "Modifier state checks passed."
