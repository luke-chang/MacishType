#!/bin/sh
# Runs an isolated fcitx5 (private DBus session, scratch config, no display
# frontends) with the user-dir addon install, then drives it with
# typing_client.py. The user's running fcitx5 is never touched.
#
# Usage: test/isolated.sh <engine-id> [key specs for typing_client.py...]
# Output: typing_client.py JSON lines on stdout; fcitx5 log in
#         $ISOLATED_LOG (default /tmp/fcitx5-macishtype-isolated.log).
set -e

engine_id="$1"
[ -n "$engine_id" ] || { echo "usage: $0 <engine-id> [keys...]" >&2; exit 1; }
shift

script_dir="$(cd "$(dirname "$0")" && pwd)"
log_file="${ISOLATED_LOG:-/tmp/fcitx5-macishtype-isolated.log}"
# Caller-provided homes persist across runs (the settings test verifies values
# survive a reload; the discovery test mutates a writable engines layer);
# scratch otherwise. One cleanup handler for both — a second `trap ... EXIT`
# would silently replace the first.
scratch_dirs=""
cleanup() { [ -n "$scratch_dirs" ] && rm -rf $scratch_dirs; }
trap cleanup EXIT

if [ -n "$ISOLATED_CONFIG_HOME" ]; then
    config_root="$ISOLATED_CONFIG_HOME"
    mkdir -p "$config_root"
else
    config_root="$(mktemp -d)"
    scratch_dirs="$scratch_dirs $config_root"
fi
# XDG_DATA_HOME is always isolated: the addon links engine icons into
# $XDG_DATA_HOME/icons and bumps that tree's mtime to make desktops rescan
# their icon theme, which must never reach the developer's own session.
if [ -n "$ISOLATED_DATA_HOME" ]; then
    data_home="$ISOLATED_DATA_HOME"
else
    data_home="$(mktemp -d)"
    scratch_dirs="$scratch_dirs $data_home"
fi
mkdir -p "$data_home"

# Scratch profile: the engine under test is the default IM of the only group.
mkdir -p "$config_root/fcitx5"
cat > "$config_root/fcitx5/profile" <<EOF
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=macishtype-$engine_id

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=macishtype-$engine_id
Layout=

[GroupOrder]
0=Default
EOF

export FCITX_ADDON_DIRS="$HOME/.local/lib/fcitx5:/usr/lib/$(gcc -dumpmachine 2>/dev/null || echo x86_64-linux-gnu)/fcitx5"
# Fixture engines join through the system XDG layer, so tests never write
# into the user's engine folders. The isolated data home takes the user layer
# (a writable engines layer for tests that mutate folders there), and the real
# ~/.local/share joins as a lower layer so the dev-installed addon conf,
# runtime and data tables stay visible; fixtures keep priority over both.
export XDG_DATA_HOME="$data_home"
export XDG_DATA_DIRS="$script_dir/fixtures/share:$HOME/.local/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export XDG_CONFIG_HOME="$config_root"
# System-layer engines put their storage under XDG state; keep it in the
# scratch unless the caller wants to reach in (storage tests do).
export XDG_STATE_HOME="${ISOLATED_STATE_HOME:-$config_root/state}"

dbus-run-session -- sh -c '
    WAYLAND_DISPLAY= DISPLAY= fcitx5 \
        --disable=wayland,waylandim,xcb,classicui,notifications \
        --verbose=default=4,macishtype=5 > "$1" 2>&1 &
    fcitx_pid=$!
    sleep 2
    log_file="$1"
    shift
    if python3 "$0" "$@"; then
        status=0
    else
        status=$?
        echo "--- fcitx5 log tail ---" >&2
        tail -30 "$log_file" >&2
    fi
    kill "$fcitx_pid" 2>/dev/null
    wait "$fcitx_pid" 2>/dev/null
    exit $status
' "$script_dir/typing_client.py" "$log_file" "macishtype-$engine_id" "$@"
