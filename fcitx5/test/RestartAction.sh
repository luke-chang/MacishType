#!/bin/sh
# The single reload notice, end to end. Every engine change since the user
# last dismissed it folds into one notification (replaced in place), each
# engine listed once in the group of its latest change, and the restart
# action appears whenever a restart would apply something — a drifted entry
# or a vanished folder — regardless of what this round changed. Pressing the
# action restarts fcitx5, after which the entry finally carries the new
# name.
#
# The client impersonates the desktop notification daemon, so nothing here
# touches the user's session or their running fcitx5. Each step waits for
# fcitx5's coalesced publish (waitnotify) before the next mutation.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

data_home="$(mktemp -d)"
trap 'rm -rf "$data_home"' EXIT

engines="$data_home/fcitx5/macishtype/engines"
alpha="$engines/alpha"
beta="$engines/beta"

write_manifest() {
    cat > "$1/manifest.json" <<EOF
{ "entry": "index.js", "name": { "en": "$2" },
  "candidateWindow": { "layoutDirection": "horizontal" } }
EOF
}

write_index() {
    cat > "$1/index.js" <<EOF
export default class {
  handleKey(event) {
    if (event.key === "a") {
      event.commit("$2");
      return true;
    }
    return false;
  }
}
EOF
}

# Both folders exist before fcitx starts, so they are part of the startup
# baseline. Beta's name carries a markup character on purpose.
mkdir -p "$alpha" "$beta"
write_manifest "$alpha" "Alpha"
write_index "$alpha" a1
write_manifest "$beta" "Beta & Co"
write_index "$beta" b1

log=/tmp/fcitx5-macishtype-restartaction.log
client_out=/tmp/fcitx5-macishtype-restartaction-client.log
: > "$client_out"
: > "$log"
LANGUAGE= LANG=C LC_ALL=C LC_MESSAGES=C \
ISOLATED_LOG="$log" ISOLATED_DATA_HOME="$data_home" \
    "$root/test/Isolated.sh" alpha \
    --notifications \
    a \
    waitnotify:1 \
    waitnotify:2 \
    waitnotify:3 \
    closenotify \
    waitnotify:4 \
    waitnotify:5 \
    waitnotify:6 \
    waitnotify:7 \
    iminfo \
    invokeaction:restart \
    sleep:6000 \
    iminfo \
    > "$client_out" 2>&1 &
runner_pid=$!

wait_for() {
    i=0
    while [ "$i" -lt 400 ]; do
        if grep -qF "$1" "$client_out"; then
            return 0
        fi
        if ! kill -0 "$runner_pid" 2>/dev/null; then
            break
        fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "FAIL: timed out waiting for: $1" >&2
    grep -a . "$client_out" | tail -20 >&2
    kill "$runner_pid" 2>/dev/null
    exit 1
}

# 1. Burst: two engines edited back to back must coalesce into ONE notice.
wait_for '"text": "a1"}'
write_index "$alpha" a2
write_index "$beta" b2
# 2. Alpha again: it moves to the tail, and the notice is replaced in place.
wait_for '"event": "notify-count", "count": 1}'
write_index "$alpha" a3
# 3. Alpha breaks: it leaves the reloaded group for the failed one.
wait_for '"event": "notify-count", "count": 2}'
printf 'export default class { handleKey( {\n' > "$alpha/index.js"
# 4. The user dismissed the notice; the next change starts a fresh one.
wait_for '"event": "notify-closed"'
write_index "$alpha" a4
# 5. Beta's folder vanishes: its entry is parked, which alone warrants the
#    restart action (no entry field has drifted yet).
wait_for '"event": "notify-count", "count": 4}'
rm -rf "$beta"
# 6. Beta returns: no longer parked, so the action goes away again.
wait_for '"event": "notify-count", "count": 5}'
mkdir -p "$beta"
write_manifest "$beta" "Beta & Co"
write_index "$beta" b3
# 7. Alpha is renamed: a drifted entry warrants the action on its own.
#    manifest.json before index.js, so the new manifest is in by the time
#    the reload it proves has happened.
wait_for '"event": "notify-count", "count": 6}'
write_manifest "$alpha" "Alpha Renamed"
write_index "$alpha" a5
wait "$runner_pid"

out="$(cat "$client_out")"
flog="$(cat "$log")"

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -30 >&2
        exit 1
    fi
}

notify_line() {
    printf '%s\n' "$out" | grep -aF '"event": "notify"' | sed -n "${1}p"
}

body_of() {
    notify_line "$1" | sed 's/.*"body": "//; s/", "actions".*//'
}

expect_equal() {
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        echo "      want: $3" >&2
        echo "      got:  $2" >&2
        exit 1
    fi
}

expect_body() {
    expect_equal "$2" "$(body_of "$1")" "$3"
}

expect_equal "seven changes across two engines produced seven notices" \
    "$(printf '%s\n' "$out" | grep -acF '"event": "notify"' || true)" 7

# Either order: the two debounce timers fire within a few milliseconds.
body1="$(body_of 1)"
case "$body1" in
"Alpha, Beta &amp; Co reloaded" | "Beta &amp; Co, Alpha reloaded")
    echo "PASS: a burst of two reloads coalesces into one notice, names escaped" ;;
*)
    echo "FAIL: burst body was '$body1'" >&2
    exit 1 ;;
esac
check "a plain reload carries no restart action" "$(notify_line 1)" \
    '"actions": []'
check "the notice never times out" "$(notify_line 1)" '"timeout": 0'
check "a single group keeps its own summary" "$(notify_line 1)" \
    '"summary": "Engine reloaded"'

expect_body 2 "an engine changed again moves to the tail of its group" \
    "Beta &amp; Co, Alpha reloaded"
id1="$(notify_line 1 | sed 's/.*"id": //; s/}.*//')"
check "the second notice replaces the first in place" "$(notify_line 2)" \
    "\"replaces\": $id1,"

expect_body 3 "a failing engine leaves the reloaded group for the failed one" \
    "Beta &amp; Co reloaded; Alpha failed to load · See the fcitx5 log for details"
check "mixed groups switch to the neutral summary" "$(notify_line 3)" \
    '"summary": "Engine status changed"'

expect_body 4 "dismissing the notice starts the next round from scratch" \
    "Alpha reloaded"
check "the fresh round is a new notification" "$(notify_line 4)" \
    '"replaces": 0,'

expect_body 5 "a vanished folder joins the notice and calls for a restart" \
    "Alpha reloaded; Beta &amp; Co removed from disk · Restore the folder to recover; Restart fcitx5 to update the input method list"
check "a parked entry alone offers the restart action" "$(notify_line 5)" \
    '"restart", "Restart Now"'

expect_body 6 "the restored folder rejoins the reloaded group" \
    "Alpha, Beta &amp; Co reloaded"
check "with nothing parked the action is withdrawn" "$(notify_line 6)" \
    '"actions": []'

expect_body 7 "a renamed engine calls for a restart on its own" \
    "Beta &amp; Co, Alpha Renamed reloaded; Restart fcitx5 to update the input method list"
check "a drifted entry offers the restart action" "$(notify_line 7)" \
    '"restart", "Restart Now"'

expect_equal "the entry stays frozen until the action restarts fcitx5" \
    "$(printf '%s\n' "$out" | grep -aF '"event": "iminfo"' |
        sed 's/.*"name": "//; s/".*//' | paste -sd, -)" \
    "Alpha,Alpha Renamed"

restarts="$(printf '%s\n' "$flog" | grep -acF "MacishType " || true)"
if [ "$restarts" -ge 2 ]; then
    echo "PASS: fcitx5 came back up (addon loaded $restarts times)"
else
    echo "FAIL: addon loaded $restarts time(s), expected a restart" >&2
    exit 1
fi
check "the restart requirement is logged" "$flog" \
    'Entry fields changed, restart fcitx5 to update the input method list: alpha'

echo "Reload notice checks passed."
