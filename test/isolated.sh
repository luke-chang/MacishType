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
# A caller-provided config home persists across runs (the settings test
# verifies values survive a reload); scratch otherwise.
if [ -n "$ISOLATED_CONFIG_HOME" ]; then
    config_root="$ISOLATED_CONFIG_HOME"
    mkdir -p "$config_root"
else
    config_root="$(mktemp -d)"
    trap 'rm -rf "$config_root"' EXIT
fi

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
# into the user's engine folders.
export XDG_DATA_DIRS="$script_dir/fixtures/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
# A caller-provided data home gives the test a writable user engines layer
# (the discovery test mutates folders there). The real ~/.local/share then
# joins as a lower layer so the dev-installed addon conf and runtime stay
# visible; fixtures keep priority over it.
if [ -n "$ISOLATED_DATA_HOME" ]; then
    mkdir -p "$ISOLATED_DATA_HOME"
    export XDG_DATA_HOME="$ISOLATED_DATA_HOME"
    export XDG_DATA_DIRS="$script_dir/fixtures/share:$HOME/.local/share:${XDG_DATA_DIRS#"$script_dir/fixtures/share:"}"
fi
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
