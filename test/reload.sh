#!/bin/sh
# Hot reload: editing an engine data file while fcitx5 runs (and the input
# method stays active) takes effect on the next keystrokes. Builds a scratch
# engine from the example engine folder (same prerequisite as isolated.sh).
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

engines_dir="$HOME/.local/share/fcitx5/macishtype/engines"
fixture="$engines_dir/reloadtest"
rm -rf "$fixture"
mkdir -p "$fixture"
cp -L "$engines_dir/example/index.js" "$engines_dir/example/manifest.json" \
    "$fixture/"
printf 'hi 甲,乙\n' > "$fixture/demo.txt"
trap 'rm -rf "$fixture"' EXIT

# The client types hi+space, idles while the shell rewrites demo.txt (the
# engine reloads under the still-focused context), then types hi+space
# again. h=104:43 i=105:31 space=32:65.
output="$(
    ISOLATED_LOG=/tmp/fcitx5-macishtype-reload.log "$root/test/isolated.sh" \
        reloadtest \
        104:43 105:31 32:65 sleep:2500 104:43 105:31 32:65 &
    client=$!
    sleep 3
    printf 'hi 丙,丁\n' > "$fixture/demo.txt"
    wait $client
)"

check() {
    if printf '%s\n' "$output" | grep -qF "$2"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$output" >&2
        exit 1
    fi
}

check "typing before the edit uses the old table" \
    '{"event": "commit", "text": "甲"}'
check "typing after the edit uses the reloaded table" \
    '{"event": "commit", "text": "丙"}'
echo "Hot reload checks passed."
