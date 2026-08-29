#!/bin/sh
# Engine icons are installed into the user's hicolor theme and panels are
# served the theme NAME, because SNI/dbusmenu panels only accept a name in
# their icon field and render a path as a missing icon. Asserts what is
# installed and what is served (including every fall-back-to-path case), that
# the icon search path is nudged so desktops rescan, and that the orphan sweep
# can only ever delete this addon's own symlinks.
#
# Runs entirely inside a scratch XDG data home, so nothing here can reach the
# developer's own icon theme.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-icontheme.log
client_out=/tmp/fcitx5-macishtype-icontheme-client.log
data_home="$(mktemp -d)"
engines="$data_home/fcitx5/macishtype/engines"
apps="$data_home/icons/hicolor/scalable/apps"
trap 'rm -rf "$data_home"' EXIT

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -20 >&2
        exit 1
    fi
}

check_absent() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -20 >&2
        exit 1
    else
        echo "PASS: $1"
    fi
}

# Filesystem predicates: the installed entries are the product under test, so
# most assertions are about them rather than about client output.
check_shell() {
    if eval "$2"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 ($2)" >&2
        ls -l "$apps" 2>/dev/null >&2 || true
        exit 1
    fi
}

# A minimal engine in the writable user layer. $1 = id, $2 = icon file name
# ("" installs no icon at all).
write_engine() {
    mkdir -p "$engines/$1"
    cat > "$engines/$1/manifest.json" <<EOF
{ "entry": "index.js", "name": { "en": "$1" } }
EOF
    printf 'export default class { handleKey() { return false; } }\n' \
        > "$engines/$1/index.js"
    if [ -n "$2" ]; then
        # Valid enough to be a real file; nothing renders it in these tests.
        printf '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"/>\n' \
            > "$engines/$1/$2"
    fi
}

# --- The fixture engine ships icon-symbolic.svg: name served, link installed --
out="$(ISOLATED_DATA_HOME="$data_home" ISOLATED_LOG="$log" \
    "$root/test/Isolated.sh" fixture iminfo 2> /dev/null)"

check "a symbolic SVG is served as a theme name, not a path" \
    "$out" '"icon": "macishtype-fixture-symbolic"'
check_shell "the theme entry is a symlink under scalable/apps" \
    "[ -L '$apps/macishtype-fixture-symbolic.svg' ]"
check_shell "it points at the engine's icon-symbolic.svg" \
    "[ \"\$(readlink '$apps/macishtype-fixture-symbolic.svg')\" = \
      '$root/test/fixtures/share/fcitx5/macishtype/engines/fixture/icon-symbolic.svg' ]"
# The system hicolor index.theme must keep winning; ours would shadow it and
# break icon lookup for every other application.
check_shell "no index.theme is written into the user theme" \
    "[ ! -e '$data_home/icons/hicolor/index.theme' ]"

# --- A plain (non-symbolic) SVG drops the suffix, in file and in name --------
write_engine plainicon icon.svg
out="$(ISOLATED_DATA_HOME="$data_home" "$root/test/Isolated.sh" plainicon iminfo \
    2> /dev/null)"
check "a plain SVG is served without the -symbolic suffix" \
    "$out" '"icon": "macishtype-plainicon"'
check_shell "its entry is macishtype-<id>.svg" \
    "[ -L '$apps/macishtype-plainicon.svg' ]"

# --- PNG has no legal home in the theme: keep serving the path --------------
write_engine pngicon icon.png
out="$(ISOLATED_DATA_HOME="$data_home" "$root/test/Isolated.sh" pngicon iminfo \
    2> /dev/null)"
check "a PNG-only engine is still served by absolute path" \
    "$out" '"icon": "'"$engines"'/pngicon/icon.png"'
check_shell "no theme entry is installed for a PNG icon" \
    "[ ! -e '$apps/macishtype-pngicon.svg' ] && \
     [ ! -e '$apps/macishtype-pngicon.png' ]"

# --- An id ending in -symbolic would claim the recolorable name --------------
write_engine weird-symbolic icon.svg
out="$(ISOLATED_DATA_HOME="$data_home" "$root/test/Isolated.sh" weird-symbolic \
    iminfo 2> /dev/null)"
check "an id ending in -symbolic falls back to the path" \
    "$out" '"icon": "'"$engines"'/weird-symbolic/icon.svg"'
check_shell "and installs nothing" \
    "[ ! -e '$apps/macishtype-weird-symbolic.svg' ]"

# --- An engine with no icon at all serves nothing ---------------------------
write_engine noicon ""
out="$(ISOLATED_DATA_HOME="$data_home" "$root/test/Isolated.sh" noicon iminfo \
    2> /dev/null)"
check "an engine without an icon serves an empty icon" \
    "$out" '"icon": ""'

# --- Switching variants replaces the entry rather than leaving both ---------
# plainicon shipped icon.svg above; giving it icon-symbolic.svg makes the
# symbolic candidate win, so the old file name must go.
printf '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"/>\n' \
    > "$engines/plainicon/icon-symbolic.svg"
out="$(ISOLATED_DATA_HOME="$data_home" "$root/test/Isolated.sh" plainicon iminfo \
    2> /dev/null)"
check "a variant switch serves the new name" \
    "$out" '"icon": "macishtype-plainicon-symbolic"'
check_shell "the new entry exists" \
    "[ -L '$apps/macishtype-plainicon-symbolic.svg' ]"
check_shell "and the superseded entry is gone" \
    "[ ! -e '$apps/macishtype-plainicon.svg' ]"

# --- The search path is nudged so desktops rescan ---------------------------
# A file appearing inside an already-scanned icon directory is not noticed by
# toolkits on its own; bumping the search path root's mtime is what triggers
# the rescan, so the root must end up newer than the directory holding the
# links.
check_shell "the icon search path is newer than the entries it must expose" \
    "[ '$data_home/icons' -nt '$apps' ]"
check "the nudge is logged once per batch, not per engine" \
    "$(grep -c 'for an icon theme rescan' "$log")" '1'

# --- The sweep deletes only this addon's own symlinks -----------------------
mkdir -p "$apps" "$data_home/icons/hicolor/48x48/apps"
ln -sfn /nonexistent "$apps/macishtype-ghost-symbolic.svg"
ln -sfn /nonexistent "$apps/macishtype-ghost-symbolic.svg.tmp-4242"
ln -sfn /nonexistent "$data_home/icons/hicolor/48x48/apps/macishtype-ghost.png"
ln -sfn /nonexistent "$apps/unrelated-symbolic.svg"
printf 'a user file that happens to use our name\n' > "$apps/macishtype-mine.svg"
ISOLATED_DATA_HOME="$data_home" "$root/test/Isolated.sh" fixture iminfo \
    > /dev/null 2>&1

check_shell "the sweep removes a stale entry of ours" \
    "[ ! -e '$apps/macishtype-ghost-symbolic.svg' ]"
check_shell "the sweep removes an interrupted staging file" \
    "[ ! -e '$apps/macishtype-ghost-symbolic.svg.tmp-4242' ]"
check_shell "the sweep reaches size directories, not just scalable" \
    "[ ! -e '$data_home/icons/hicolor/48x48/apps/macishtype-ghost.png' ]"
check_shell "the sweep never touches a symlink that is not ours" \
    "[ -L '$apps/unrelated-symbolic.svg' ]"
check_shell "the sweep never deletes a regular file, even with our name" \
    "[ -f '$apps/macishtype-mine.svg' ]"
check_shell "the live engine keeps its entry through a sweep" \
    "[ -L '$apps/macishtype-fixture-symbolic.svg' ]"

# --- A folder removed at runtime keeps its entry ----------------------------
# fcitx cannot drop the input method from its list, so the engine is parked;
# removing its icon would only turn a stale icon into a missing one, and
# keeping the file name lets a restored folder just re-point the link. This
# pins that deliberate choice.
write_engine parkme icon-symbolic.svg
: > "$client_out"
# C locale: the wait below keys on the load-failure prompt, which is translated.
LANGUAGE= LANG=C LC_ALL=C LC_MESSAGES=C \
    ISOLATED_DATA_HOME="$data_home" ISOLATED_LOG="$log" \
    "$root/test/Isolated.sh" parkme a sleep:2500 a sleep:1500 \
    > "$client_out" 2>&1 &
runner_pid=$!
wait_for() {
    i=0
    while [ "$i" -lt 300 ]; do
        grep -qF "$1" "$client_out" && return 0
        kill -0 "$runner_pid" 2>/dev/null || break
        i=$((i + 1))
        sleep 0.1
    done
    echo "FAIL: timed out waiting for: $1" >&2
    tail -20 "$client_out" >&2
    kill "$runner_pid" 2>/dev/null
    exit 1
}
wait_for '"event": "key-result"'
rm -rf "$engines/parkme"
wait_for 'Engine load failed'
wait "$runner_pid" || true

check_shell "a parked engine keeps its theme entry" \
    "[ -L '$apps/macishtype-parkme-symbolic.svg' ]"
# ...and the next startup is what cleans it up, now that the folder is gone.
ISOLATED_DATA_HOME="$data_home" "$root/test/Isolated.sh" fixture iminfo \
    > /dev/null 2>&1
check_shell "the next start sweeps the vanished engine's entry" \
    "[ ! -e '$apps/macishtype-parkme-symbolic.svg' ]"

# --- Uninstall cleanup: at teardown the addon probes whether the library it
# was loaded from is still on disk. Present (a normal restart): the theme
# links stay. Gone (the package was removed mid-session): it deletes them. ---
addon_scratch="$(mktemp -d)"
keep_home="$(mktemp -d)"
gone_home="$(mktemp -d)"
trap 'rm -rf "$data_home" "$addon_scratch" "$keep_home" "$gone_home"' EXIT
cp "$HOME/.local/lib/fcitx5/libmacishtype.so" "$addon_scratch/"
scratch_addon_dirs="$addon_scratch:$("$root/test/SystemAddonDir.sh")"

ISOLATED_DATA_HOME="$keep_home" ISOLATED_ADDON_DIRS="$scratch_addon_dirs" \
    ISOLATED_LOG="$log" "$root/test/Isolated.sh" fixture sleep:200 \
    > /dev/null 2>&1
check_shell "links survive a shutdown while the library remains on disk" \
    "ls '$keep_home/icons/hicolor/scalable/apps/' | grep -q '^macishtype-'"

ISOLATED_DATA_HOME="$gone_home" ISOLATED_ADDON_DIRS="$scratch_addon_dirs" \
    ISOLATED_LOG="$log" "$root/test/Isolated.sh" fixture sleep:3000 \
    > /dev/null 2>&1 &
client=$!
sleep 3
rm "$addon_scratch/libmacishtype.so"
wait $client
check_shell "links are removed when the library is gone at shutdown" \
    "! ls '$gone_home/icons/hicolor/scalable/apps/' 2> /dev/null \
        | grep -q '^macishtype-'"

echo "Icon-theme checks passed."
