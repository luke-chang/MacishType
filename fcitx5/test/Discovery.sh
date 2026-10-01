#!/bin/sh
# Engine-folder lifecycle: a folder dropped in at runtime surfaces through
# fcitx's native pull path (CheckUpdate accept -> Refresh re-enters
# listInputMethods), edits hot-reload by default or defer to the next
# Refresh when AutoReloadEngines is off, deletion parks the engine with a
# typing prompt instead of a dead passthrough, and restoring the folder
# recovers typing on the context the user stayed on (lazy session rebuild).
#
# The client run is event-driven: folder mutations fire on observed client
# output, and the client resumes on what each one produces (a log line, or
# the shell's marker file) rather than on absolute timing.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$MACISHTYPE_TEST_INSTALLED" ] || make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-discovery.log
client_out=/tmp/fcitx5-macishtype-discovery-client.log
data_home="$(mktemp -d)"
data_home2="$(mktemp -d)"
# Markers the shell drops once a step is written, for the client's waitfile:.
marks="$(mktemp -d)"
engine_dir="$data_home/fcitx5/macishtype/engines/dynFixture"
trap 'rm -rf "$data_home" "$data_home2" "$marks"' EXIT

write_engine() {
    mkdir -p "$engine_dir"
    cat > "$engine_dir/manifest.json" <<'EOF'
{ "entry": "index.js", "name": { "en": "Dyn Fixture" } }
EOF
    edit_engine "$1"
}

# Each version logs its load: one edit can reload more than once, so the
# client waits on the version it needs rather than counting reloads.
edit_engine() {
    cat > "$engine_dir/index.js" <<EOF
console.log("loaded $1");
export default class {
  handleKey(event) {
    if (event.key === "a") {
      event.commit("$1");
      return true;
    }
    return false;
  }
}
EOF
}

: > "$client_out"
# Pin the locale so the load-failure prompt renders in English (matching the
# assertion) regardless of the developer's environment language.
LANGUAGE= LANG=C LC_ALL=C LC_MESSAGES=C \
ISOLATED_LOG="$log" ISOLATED_DATA_HOME="$data_home" \
    "$root/test/Isolated.sh" fixture \
    checkupdate \
    "waitfile:$marks/dyn" \
    checkupdate \
    refresh \
    "setgroupims:keyboard-us,macishtype-fixture,macishtype-dynFixture" \
    switchim:macishtype-dynFixture \
    a \
    'waitlog:1:[dynFixture] loaded dyn2' \
    a \
    "setaddonopt:macishtype:AutoReloadEngines=False" \
    'waitlog:1:reload deferred to the next update: dynFixture' \
    a \
    checkupdate \
    refresh \
    a \
    'waitlog:1:Engine folder removed: dynFixture' \
    a \
    65307:9:0 \
    'waitlog:1:[dynFixture] loaded dyn4' \
    a \
    > "$client_out" 2>&1 &
runner_pid=$!

wait_for() {
    i=0
    while [ "$i" -lt 300 ]; do
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

# Each trigger reacts to an observed client event, and the client resumes on
# the log line the trigger produces, keeping the schedule deterministic.
wait_for '"value": false'            # step 1 passed the clean baseline
# CheckUpdate compares whole-second mtimes against the startup scan, so the
# new folder must land in a later second.
sleep 1
write_engine dyn                     # -> step 2 discovers it via Refresh
touch "$marks/dyn"
wait_for '"text": "dyn"}'
edit_engine dyn2                     # -> step 3: default hot reload
wait_for '"event": "addon-opt-set"'
edit_engine dyn3                     # -> step 4: deferred until Refresh
wait_for '"text": "dyn3"}'
rm -rf "$engine_dir"                 # -> step 5: defunct + typing prompt
wait_for 'Engine load failed'
write_engine dyn4                    # -> step 6: automatic recovery
wait "$runner_pid"

out="$(cat "$client_out")"
flog="$(cat "$log")"

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -25 >&2
        exit 1
    fi
}

ordered() {
    first="$(printf '%s\n' "$out" | grep -naF "$2" | head -1 | cut -d: -f1)"
    second="$(printf '%s\n' "$out" | grep -naF "$3" | head -1 | cut -d: -f1)"
    if [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 (positions: $first vs $second)" >&2
        exit 1
    fi
}

checkupdates="$(printf '%s\n' "$out" | grep -aF '"event": "checkupdate"' |
    sed 's/.*"value": //; s/}.*//' | paste -sd, -)"
if [ "$checkupdates" = "false,true,true" ]; then
    echo "PASS: CheckUpdate reads clean, then folder-add, then deferred edits"
else
    echo "FAIL: checkupdate sequence was '$checkupdates' (want false,true,true)" >&2
    exit 1
fi

check "a runtime folder joins the IM list through Refresh and commits" \
    "$out" '"text": "dyn"}'
check "editing with auto-reload on hot-reloads (default unchanged)" \
    "$out" '"text": "dyn2"}'
check "the deferred edit applies on the next Refresh" \
    "$out" '"text": "dyn3"}'
check "typing on the deleted engine shows the load-failure prompt" \
    "$out" '"text": "Engine load failed", "cursor": 18,'
check "restoring the folder recovers typing without re-activation" \
    "$out" '"text": "dyn4"}'
ordered "the deferred edit keeps the old table until Refresh" \
    '"text": "dyn3"}' '"text": "Engine load failed"'
ordered "Escape clears the prompt" \
    '"text": "Engine load failed"' '"event": "preedit", "text": ""'

check "runtime discovery is logged" "$flog" 'Engine discovered: dynFixture'
check "the deferred reload is logged" "$flog" \
    'reload deferred to the next update: dynFixture'
check "the folder removal is logged" "$flog" \
    'Engine folder removed: dynFixture'

# A new folder whose manifest does not parse must keep the update affordance
# live: fixing the manifest in place does NOT change the engines/ mtime, so
# without the unparsable-manifest flag the fixed engine would never surface
# until a restart. brokenfix exists before fcitx starts, so its creation is
# folded into the startup baseline — CheckUpdate here is driven purely by the
# flag, not by an mtime bump.
broken_dir="$data_home2/fcitx5/macishtype/engines/brokenfix"
mkdir -p "$broken_dir"
printf 'this is not json\n' > "$broken_dir/manifest.json"
cat > "$broken_dir/index.js" <<'EOF'
export default class {
  handleKey(event) {
    if (event.key === "a") { event.commit("fixed"); return true; }
    return false;
  }
}
EOF

client_out=/tmp/fcitx5-macishtype-discovery-client2.log
: > "$client_out"
LANGUAGE= LANG=C LC_ALL=C LC_MESSAGES=C \
ISOLATED_LOG=/tmp/fcitx5-macishtype-discovery2.log \
ISOLATED_DATA_HOME="$data_home2" \
    "$root/test/Isolated.sh" fixture \
    checkupdate \
    "waitfile:$marks/fixed" \
    refresh \
    "setgroupims:keyboard-us,macishtype-fixture,macishtype-brokenfix" \
    switchim:macishtype-brokenfix \
    a \
    checkupdate \
    > "$client_out" 2>&1 &
runner_pid=$!

# Fix the manifest while the client waits, before its refresh.
wait_for '"event": "checkupdate"'
printf '{ "entry": "index.js", "name": { "en": "Broken Fix" } }\n' \
    > "$broken_dir/manifest.json"
touch "$marks/fixed"
wait "$runner_pid"

out2="$(cat "$client_out")"
checkupdates2="$(printf '%s\n' "$out2" | grep -aF '"event": "checkupdate"' |
    sed 's/.*"value": //; s/}.*//' | paste -sd, -)"
if [ "$checkupdates2" = "true,false" ]; then
    echo "PASS: an unparsable new manifest keeps CheckUpdate hot until fixed"
else
    echo "FAIL: broken-manifest checkupdate was '$checkupdates2' (want true,false)" >&2
    printf '%s\n' "$out2" | tail -20 >&2
    exit 1
fi
check "fixing the manifest in place surfaces the engine on the next Refresh" \
    "$out2" '"text": "fixed"}'

echo "Engine-folder lifecycle checks passed."
