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
trap 'rm -rf "$state_dir"' EXIT
storage_dir="$state_dir/fcitx5/macishtype/fixture"

# The client activates the fixture (whose activate() writes key "own"),
# idles while the shell drops key "ext" plus a foreign file into the
# storage directory, then idles again so the dispatched event's log line
# lands before exit. digit5=53:14 keeps the timeline; the fixture handles
# no keys. Key files carry the cross-platform localStorage_ prefix.
ISOLATED_LOG="$log_file" ISOLATED_STATE_HOME="$state_dir" \
    "$root/test/Isolated.sh" fixture sleep:2500 53:14 sleep:1500 \
    > /dev/null &
client=$!
sleep 4
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
