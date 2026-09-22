#!/bin/sh
# The entry fields fcitx freezes at registration — display name, language
# code, configurable — cannot be updated at runtime: its input method list
# only ever grows. Editing one therefore has to surface as an update
# affordance that, unlike every other CheckUpdate condition, SURVIVES the
# Refresh that cannot apply it, plus a log line naming the restart.
#
# One isolated fcitx5 per case. The engine folder exists before fcitx starts
# (a later creation would light CheckUpdate through the mtime baseline), the
# manifest changes while the client sleeps, and a changed commit string
# proves the reload landed. AutoReloadEngines stays at its default: with no
# deferred reload pending, and an in-folder edit leaving the engines layer's
# own mtime alone, a true reading can only come from the drifted fields.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

scratch=""
trap 'rm -rf $scratch' EXIT

# A fixed candidate window direction and no settings section leave the
# engine with nothing configurable.
write_manifest() {
    cat > "$1/manifest.json" <<EOF
{ "entry": "index.js", "name": { "en": "$2" },
  "candidateWindow": { "layoutDirection": "horizontal" }$3 }
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

rename_engine() {
    write_manifest "$1" "Renamed Fixture" ""
}

add_settings() {
    write_manifest "$1" "Entry Fixture" ',
  "settings": [
    {
      "title": { "en": "Test" },
      "fields": [
        { "key": "flag", "type": "toggle", "label": { "en": "Flag" },
          "default": true }
      ]
    }
  ]'
}

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -25 >&2
        exit 1
    fi
}

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

# $1 what the case is about, $2 engine id, $3 function that edits the manifest.
run_case() {
    data_home="$(mktemp -d)"
    scratch="$scratch $data_home"
    engine_dir="$data_home/fcitx5/macishtype/engines/$2"
    mkdir -p "$engine_dir"
    write_manifest "$engine_dir" "Entry Fixture" ""
    write_index "$engine_dir" before

    log="/tmp/fcitx5-macishtype-entryfields-$2.log"
    client_out="/tmp/fcitx5-macishtype-entryfields-$2-client.log"
    : > "$client_out"
    LANGUAGE= LANG=C LC_ALL=C LC_MESSAGES=C \
    ISOLATED_LOG="$log" ISOLATED_DATA_HOME="$data_home" \
        "$root/test/Isolated.sh" "$2" \
        checkupdate \
        a \
        sleep:2000 \
        a \
        checkupdate \
        refresh \
        checkupdate \
        > "$client_out" 2>&1 &
    runner_pid=$!

    # manifest.json before index.js: should the two writes straddle the
    # 300ms debounce they become two reloads, and only this order guarantees
    # the new manifest is already in when the new commit string proves one
    # happened.
    wait_for '"text": "before"}'
    "$3" "$engine_dir"
    write_index "$engine_dir" after
    wait "$runner_pid"

    out="$(cat "$client_out")"
    sequence="$(printf '%s\n' "$out" | grep -aF '"event": "checkupdate"' |
        sed 's/.*"value": //; s/}.*//' | paste -sd, -)"
    if [ "$sequence" = "false,true,true" ]; then
        echo "PASS: $1 lights CheckUpdate and stays lit past Refresh"
    else
        echo "FAIL: $1: checkupdate was '$sequence', want false,true,true" >&2
        printf '%s\n' "$out" | tail -20 >&2
        exit 1
    fi
    check "the reload behind it applied ($2)" "$out" '"text": "after"}'
    check "the restart requirement is logged ($2)" "$(cat "$log")" \
        "Entry fields changed, restart fcitx5 to update the input method list: $2"
}

run_case "a renamed engine" entryFixture rename_engine
# configurable is frozen too: the settings compose and work, but the entry
# offers no way in.
run_case "a newly configurable engine" configFixture add_settings

echo "Registered entry field checks passed."
