#!/bin/sh
# Milestone acceptance: MacishType's ExampleEngine, unmodified, types end to
# end through an isolated fcitx5. Requires the example engine folder to be
# present (a symlink to the MacishType repo's ExampleEngine works):
#   ~/.local/share/fcitx5/macishtype/engines/example
#
# Key specs are keyval:keycode with X keycodes (evdev + 8).
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/scripts/dev-install.sh" > /dev/null

# h=104:43 i=105:31 space=32:65 digit2=50:11 escape=65307:9
# right=65363:114 enter=65293:36 digit5=53:14
run() {
    "$root/test/isolated.sh" example "$@" 2> /dev/null
}

check() {
    description="$1"
    pattern="$2"
    if printf '%s\n' "$output" | grep -qF "$pattern"; then
        echo "PASS: $description"
    else
        echo "FAIL: $description" >&2
        printf '%s\n' "$output" >&2
        exit 1
    fi
}

check_absent() {
    description="$1"
    pattern="$2"
    if printf '%s\n' "$output" | grep -qF "$pattern"; then
        echo "FAIL: $description" >&2
        printf '%s\n' "$output" >&2
        exit 1
    else
        echo "PASS: $description"
    fi
}

output="$(run 104:43 105:31 32:65)"
check "composing shows preedit" '{"event": "preedit", "text": "HI", "cursor": 2}'
check "space commits the first candidate" '{"event": "commit", "text": "哈囉"}'

output="$(run 104:43 105:31 50:11)"
check "index label 2 commits the second candidate" '{"event": "commit", "text": "嗨"}'

output="$(run 104:43 65307:9)"
check "escape clears the preedit" '{"event": "preedit", "text": "", "cursor": 0}'
check_absent "escape commits nothing" '"event": "commit"'

output="$(run 104:43 105:31 65363:114 65293:36)"
check "arrow moves highlight, enter commits it" '{"event": "commit", "text": "嗨"}'

output="$(run 53:14)"
check "idle digit passes through unhandled" '{"event": "key-result", "keyval": 53, "handled": false}'

echo "All acceptance checks passed."
