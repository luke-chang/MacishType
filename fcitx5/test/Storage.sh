#!/bin/sh
# Storage events: an external write into an engine's storage raises the
# contract's storage event, while the engine's own writes stay silent. The
# fixture engine sits in the system XDG layer, so this also exercises the
# layer rule that routes its storage to XDG_STATE_HOME instead of the
# (read-only in production) engine folder.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

state_dir="$(mktemp -d)"
log_file=/tmp/fcitx5-macishtype-storage.log
client_out=/tmp/fcitx5-macishtype-storage-client.log
trap 'rm -rf "$state_dir"' EXIT
storage_dir="$state_dir/fcitx5/macishtype/fixture"

# The client activates the fixture (whose activate() writes key "own") and
# idles past the watcher's debounce, then presses digit5=53:14, which the
# fixture leaves unhandled, as the shell's cue to drop key "ext" plus a
# foreign file into the storage directory. It waits for the dispatched event,
# then idles once more so any event that should not exist would surface. Key
# files carry the cross-platform localStorage_ prefix.
: > "$client_out"
ISOLATED_LOG="$log_file" ISOLATED_STATE_HOME="$state_dir" \
    "$root/test/Isolated.sh" fixture sleep:600 53:14 \
    'waitlog:1:storage-event ext=external' sleep:500 \
    > "$client_out" &
client=$!

wait_for() {
    i=0
    while [ "$i" -lt 300 ]; do
        if grep -qF "$1" "$client_out"; then
            return 0
        fi
        if ! kill -0 "$client" 2>/dev/null; then
            break
        fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "FAIL: timed out waiting for: $1" >&2
    tail -20 "$client_out" >&2
    kill "$client" 2>/dev/null
    exit 1
}

wait_for '"keyval": 53'
printf 'external' > "$storage_dir/localStorage_ext"
printf 'not a key file' > "$storage_dir/foreign"
wait $client

check() {
    if eval "$2"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        grep -E 'storage|fixture' "$log_file" | tail -20 >&2
        exit 1
    fi
}

check "self-write lands in the XDG state storage" \
    "[ -f '$storage_dir/localStorage_own' ]"
check "external write dispatches a storage event" \
    "grep -qF 'storage-event ext=external' '$log_file'"
check "the engine's own write does not echo back" \
    "! grep -qF 'storage-event own' '$log_file'"
check "the external write is the only dispatched event" \
    "[ \$(grep -cF 'storage-event' '$log_file') -eq 1 ]"
echo "Storage event checks passed."
