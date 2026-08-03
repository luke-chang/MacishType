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
cp -L "$engines_dir/example/index.js" "$fixture/"
# A minimal manifest (no settings / intendedLanguage) keeps this test on the
# hot-reload path without associated mode intercepting the single-char commit.
printf '{ "entry": "index.js", "name": "Reload Test" }\n' > "$fixture/manifest.json"
printf 'hi 甲,乙\n' > "$fixture/demo.txt"
trap 'rm -rf "$fixture"' EXIT

# The client types hi+space three times with idle gaps. During the first
# gap the shell writes a file the engine never read — reloads are scoped to
# the engine's tracked files, so nothing may happen. During the second gap
# it rewrites demo.txt (tracked via fetch), which reloads the engine under
# the still-focused context. h=104:43 i=105:31 space=32:65.
log_file=/tmp/fcitx5-macishtype-reload.log
output="$(
    ISOLATED_LOG="$log_file" "$root/test/isolated.sh" \
        reloadtest \
        104:43 105:31 32:65 sleep:2500 104:43 105:31 32:65 \
        sleep:2500 104:43 105:31 32:65 &
    client=$!
    sleep 3
    printf 'not read by the engine\n' > "$fixture/notes.txt"
    sleep 2.5
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

old_commits=$(printf '%s\n' "$output" | grep -cF '"text": "甲"')
if [ "$old_commits" -eq 2 ]; then
    echo "PASS: untracked file change does not reload"
else
    echo "FAIL: untracked file change does not reload (甲 x$old_commits)" >&2
    printf '%s\n' "$output" >&2
    exit 1
fi

reloads=$(grep -c 'reloading: reloadtest' "$log_file")
if [ "$reloads" -eq 1 ]; then
    echo "PASS: exactly one reload was triggered"
else
    echo "FAIL: expected 1 reload, saw $reloads" >&2
    grep 'macishtype' "$log_file" | tail -20 >&2
    exit 1
fi
echo "Hot reload checks passed."
