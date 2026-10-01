#!/bin/sh
# Hot reload: editing an engine data file while fcitx5 runs (and the input
# method stays active) takes effect on the next keystrokes. Builds a scratch
# engine from the repo's example engine, in an isolated user data layer so
# the developer's real engine folders are never touched.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

data_home="$(mktemp -d)"
trap 'rm -rf "$data_home"' EXIT
fixture="$data_home/fcitx5/macishtype/engines/reloadtest"
mkdir -p "$fixture"
cp "$root/../engines/example/index.js" "$fixture/"
# A minimal manifest (no settings / intendedLanguage) keeps this test on the
# hot-reload path without associated mode intercepting the single-char commit.
printf '{ "entry": "index.js", "name": "Reload Test" }\n' > "$fixture/manifest.json"
printf 'hi 甲,乙\n' > "$fixture/demo.txt"

# The client types hi+space three times with idle gaps. During the first
# gap the shell writes a file the engine never read — reloads are scoped to
# the engine's tracked files, so nothing may happen while the client outwaits
# the watcher's debounce. During the second gap it rewrites demo.txt (tracked
# via fetch), which reloads the engine under the still-focused context; the
# client resumes once the reloaded table is in. h=104:43 i=105:31
# space=32:65.
log_file=/tmp/fcitx5-macishtype-reload.log
client_out=/tmp/fcitx5-macishtype-reload-client.log
: > "$client_out"
ISOLATED_LOG="$log_file" ISOLATED_DATA_HOME="$data_home" \
    "$root/test/Isolated.sh" \
    reloadtest \
    104:43 105:31 32:65 "waitfile:$fixture/notes.txt" sleep:700 \
    104:43 105:31 32:65 'waitlog:2:demo.txt loaded' \
    104:43 105:31 32:65 > "$client_out" &
client=$!

# $1 a client output line, $2 how many of them to wait for.
wait_for() {
    i=0
    while [ "$i" -lt 300 ]; do
        if [ "$(grep -cF "$1" "$client_out")" -ge "$2" ]; then
            return 0
        fi
        if ! kill -0 "$client" 2>/dev/null; then
            break
        fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "FAIL: timed out waiting for: $1 x$2" >&2
    tail -20 "$client_out" >&2
    kill "$client" 2>/dev/null
    exit 1
}

# Each gap opens with the commit before it.
wait_for '{"event": "commit", "text": "甲"}' 1
printf 'not read by the engine\n' > "$fixture/notes.txt"
wait_for '{"event": "commit", "text": "甲"}' 2
printf 'hi 丙,丁\n' > "$fixture/demo.txt"
wait $client
output="$(cat "$client_out")"

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
