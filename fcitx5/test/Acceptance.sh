#!/bin/sh
# Milestone acceptance: the shared example engine, unmodified, types end to
# end through an isolated fcitx5. The engine is copied out of the repo into
# an isolated user data layer, so the run needs nothing from the developer's
# own engine folders and touches none of them.
#
# Key specs are keyval:keycode with X keycodes (evdev + 8).
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

data_home="$(mktemp -d)"
trap 'rm -rf "$data_home"' EXIT
engines="$data_home/fcitx5/macishtype/engines"
mkdir -p "$engines"
cp -R "$root/../engines/example" "$engines/example"

# h=104:43 i=105:31 space=32:65 digit2=50:11 escape=65307:9
# right=65363:114 enter=65293:36 digit5=53:14
run() {
    ISOLATED_DATA_HOME="$data_home" \
        "$root/test/Isolated.sh" example "$@"
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
check "composing shows preedit" '"text": "HI", "cursor": 2'
check "space commits the first candidate" '{"event": "commit", "text": "哈囉"}'

output="$(run 104:43 105:31 50:11)"
check "index label 2 commits the second candidate" '{"event": "commit", "text": "嗨"}'

output="$(run 104:43 65307:9)"
check "escape clears the preedit" '"text": "", "cursor": 0'
check_absent "escape commits nothing" '"event": "commit"'

output="$(run 104:43 105:31 65363:114 65293:36)"
check "arrow moves highlight, enter commits it" '{"event": "commit", "text": "嗨"}'

output="$(run 53:14)"
check "idle digit passes through unhandled" '"keyval": 53, "handled": false'

# The fixture engine (test/fixtures, joined via XDG_DATA_DIRS) declares the
# optional manifest label; its icon comes from the default base name probing,
# which must prefer the -symbolic.svg over the .png it also ships — visible
# here in the served icon-theme name (test/IconTheme.sh covers the install).
output="$("$root/test/Isolated.sh" fixture iminfo)"
check "manifest label reaches the entry" '"label": "Fx"'
check "default icon base serves an icon-theme name" \
    '"icon": "macishtype-fixture-symbolic"'

echo "All acceptance checks passed."
