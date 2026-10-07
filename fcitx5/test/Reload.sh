#!/bin/sh
# Hot reload: editing an engine data file while fcitx5 runs (and the input
# method stays active) takes effect on the next keystrokes. Builds a scratch
# engine from the repo's example engine, in an isolated user data layer so
# the developer's real engine folders are never touched.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$MACISHTYPE_TEST_INSTALLED" ] || make -s -C "$root" dev-install > /dev/null

data_home="$(mktemp -d)"
# A failed run can leave a directory without permissions behind.
trap 'chmod -R u+rwx "$data_home" || :; rm -rf "$data_home"' EXIT
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

# $1 the file to watch, $2 a line in it, $3 how many of them to wait for.
wait_for() {
    i=0
    while [ "$i" -lt 300 ]; do
        if [ "$(grep -cF "$2" "$1")" -ge "$3" ]; then
            return 0
        fi
        if ! kill -0 "$client" 2>/dev/null; then
            break
        fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "FAIL: timed out waiting for: $2 x$3" >&2
    tail -20 "$1" >&2
    kill "$client" 2>/dev/null
    exit 1
}

# $1 engine id, $2 expected reload count, $3 description.
expect_reloads() {
    reloads=$(grep -c "reloading: $1" "$log_file")
    if [ "$reloads" -eq "$2" ]; then
        echo "PASS: $3"
    else
        echo "FAIL: $3 (saw $reloads reloads)" >&2
        grep 'macishtype' "$log_file" | tail -20 >&2
        exit 1
    fi
}

# Each gap opens with the commit before it.
wait_for "$client_out" '{"event": "commit", "text": "甲"}' 1
printf 'not read by the engine\n' > "$fixture/notes.txt"
wait_for "$client_out" '{"event": "commit", "text": "甲"}' 2
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

expect_reloads reloadtest 1 "exactly one reload was triggered"

# Second engine: fetches a dotfile that exists and files it cannot read,
# and logs what it got on every load. The shell edits the dotfile, makes
# each unreadable file readable in turn, and edits files in directories that
# became reachable; every step must reload the engine exactly once. Moving a
# directory out again and editing it there must not.
fixture="$data_home/fcitx5/macishtype/engines/reloadmissing"
mkdir -p "$fixture"
printf '{ "entry": "index.js", "name": "Reload Missing Test" }\n' \
    > "$fixture/manifest.json"
cat > "$fixture/index.js" <<'JS'
const names = [
  '.hidden.txt', 'late.txt', 'later/sub.txt', 'linked.txt', 'moved/data.txt',
  'blocked/x.txt', 'folder.txt', 'private.txt', 'locked/x.txt',
  'nosearch/sub/x.txt',
];
Promise.all(names.map((name) => fetch(`./${name}`)
  .then((response) => response.text())
  .then((text) => `${name}=${text.trim()}`, () => `${name}=missing`)))
  .then((parts) => console.info(`fetch state: ${parts.join(' ')}`));
export default class { handleKey() { return false; } }
JS
printf 'one\n' > "$fixture/.hidden.txt"
# A file where the fetch expects a directory.
printf 'file\n' > "$fixture/blocked"
# A directory where the fetch expects a file.
mkdir "$fixture/folder.txt"

# Permissions do not stop root (the CI container), so the steps that lift
# them only run where they bite.
printf 'probe\n' > "$data_home/probe"
chmod 000 "$data_home/probe"
if cat "$data_home/probe" > /dev/null 2>&1; then
    permission_steps=0
else
    permission_steps=5
    printf 'private\n' > "$fixture/private.txt"
    chmod 000 "$fixture/private.txt"
    mkdir "$fixture/locked"
    printf 'locked\n' > "$fixture/locked/x.txt"
    chmod 000 "$fixture/locked"
    # Listable but not enterable: its own watch takes, its subdirectory's
    # does not.
    mkdir -p "$fixture/nosearch/sub"
    printf 'nosearch\n' > "$fixture/nosearch/sub/x.txt"
    chmod 644 "$fixture/nosearch"
fi
rm -f "$data_home/probe"
loads=$((9 + permission_steps))

log_file=/tmp/fcitx5-macishtype-reload-missing.log
# The shell polls this log before fcitx5 starts and truncates it.
: > "$log_file"
: > "$client_out"
ISOLATED_LOG="$log_file" ISOLATED_DATA_HOME="$data_home" \
    "$root/test/Isolated.sh" \
    reloadmissing "waitlog:$loads:fetch state:" > "$client_out" &
client=$!

hidden=one late=missing sub=missing linked=missing moved=missing
blocked=missing folder=missing private=missing locked=missing
nosearch=missing

# $1 description, $2 load count; the expected state comes from the
# variables above.
check_state() {
    wait_for "$log_file" 'fetch state:' "$2"
    state="$(grep -F 'fetch state:' "$log_file" | tail -1)"
    expected="fetch state: .hidden.txt=$hidden late.txt=$late"
    expected="$expected later/sub.txt=$sub linked.txt=$linked"
    expected="$expected moved/data.txt=$moved blocked/x.txt=$blocked"
    expected="$expected folder.txt=$folder private.txt=$private"
    expected="$expected locked/x.txt=$locked nosearch/sub/x.txt=$nosearch"
    case "$state" in
    *"$expected")
        echo "PASS: $1" ;;
    *)
        echo "FAIL: $1" >&2
        echo "  got: $state" >&2
        kill "$client" 2>/dev/null
        exit 1 ;;
    esac
}

check_state "missing fetch targets load as missing" 1
printf 'two\n' > "$fixture/.hidden.txt"
hidden=two
check_state "editing a fetched dotfile reloads" 2
printf 'late\n' > "$fixture/late.txt"
late=late
check_state "creating a missing fetch target reloads" 3
mkdir "$fixture/later"
printf 'sub\n' > "$fixture/later/sub.txt"
sub=sub
check_state "creating a missing target in a new directory reloads" 4
# The symlink's target is an untracked file, so writing it reloads nothing.
printf 'target\n' > "$fixture/target.txt"
sleep 0.7
ln -s target.txt "$fixture/linked.txt"
linked=target
check_state "creating a missing target as a symlink reloads" 5
mkdir -p "$data_home/staging/moved"
printf 'moved\n' > "$data_home/staging/moved/data.txt"
mv "$data_home/staging/moved" "$fixture/moved"
moved=moved
check_state "moving in a directory with a missing target reloads" 6
printf 'edited\n' > "$fixture/moved/data.txt"
moved=edited
check_state "editing a file in a moved-in directory reloads" 7
# A stray reload here would log a state that fails the next check.
mv "$fixture/moved" "$data_home/staging/gone"
sleep 0.7
printf 'outside\n' > "$data_home/staging/gone/data.txt"
sleep 0.7
rm "$fixture/blocked"
mkdir "$fixture/blocked"
printf 'x\n' > "$fixture/blocked/x.txt"
moved=missing blocked=x
check_state "a directory replacing a blocking file reloads" 8
rmdir "$fixture/folder.txt"
printf 'folder\n' > "$fixture/folder.txt"
folder=folder
check_state "a file replacing a fetched directory reloads" 9
if [ "$permission_steps" -gt 0 ]; then
    chmod 644 "$fixture/private.txt"
    private=private
    check_state "making an unreadable fetched file readable reloads" 10
    chmod 755 "$fixture/locked"
    locked=locked
    check_state "opening a directory that blocked a fetch reloads" 11
    printf 'edited\n' > "$fixture/locked/x.txt"
    locked=edited
    check_state "editing a file in an opened directory reloads" 12
    chmod 755 "$fixture/nosearch"
    nosearch=nosearch
    check_state "making a listable directory enterable reloads" 13
    printf 'edited\n' > "$fixture/nosearch/sub/x.txt"
    nosearch=edited
    check_state "editing below a directory made enterable reloads" 14
else
    echo "SKIP: permission steps (permissions do not apply to this user)"
fi
wait $client

expect_reloads reloadmissing $((loads - 1)) "each step reloaded exactly once"
echo "Hot reload checks passed."
