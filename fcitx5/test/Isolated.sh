#!/bin/sh
# Runs an isolated fcitx5 (private DBus session, scratch config, no display
# frontends) with the user-dir addon install, then drives it with
# TypingClient.py. The user's running fcitx5 is never touched.
#
# Usage: test/Isolated.sh <engine-id> [key specs for TypingClient.py...]
# Output: TypingClient.py JSON lines on stdout; fcitx5 log in
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
# Plain `if`, not `[ … ] && rm`: with both homes supplied there is nothing
# to remove, and a false test as the trap's last command would become the
# script's exit status.
cleanup() {
    if [ -n "$scratch_dirs" ]; then
        rm -rf $scratch_dirs
    fi
}
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
# fcitx5's input method popup shares the client-side panel with the engines,
# and one instance of it comes from a startup timer that can fire after the
# client has begun; keep every candidate frame the engine's own.
cat > "$config_root/fcitx5/config" <<EOF
[Behavior]
ShowInputMethodInformation=False
EOF

# ISOLATED_ADDON_DIRS lets a test load the addon from a scratch copy (the
# uninstall-cleanup test deletes it mid-run).
export FCITX_ADDON_DIRS="${ISOLATED_ADDON_DIRS:-$HOME/.local/lib/fcitx5:$("$script_dir/SystemAddonDir.sh")}"
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

# Frontends stay out. So does the notifications addon, unless the client
# impersonates the daemon (--notifications): the isolated instance must never
# reach the user's real one.
disabled_addons=wayland,waylandim,xcb,classicui,notifications
case " $* " in
*" --notifications "*) disabled_addons=wayland,waylandim,xcb,classicui ;;
esac
export disabled_addons

# The private bus activates nothing, so a name no test process owns stays
# unowned. Otherwise the desktop's services (portals, keyring, gvfs) start on
# demand inside it — a restarted fcitx5 drops the --disable list above — and
# reach the developer's own session.
bus_config="$(mktemp)"
scratch_dirs="$scratch_dirs $bus_config"
cat > "$bus_config" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <keep_umask/>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF

dbus-run-session --config-file="$bus_config" -- sh -c '
    WAYLAND_DISPLAY= DISPLAY= fcitx5 \
        --disable="$disabled_addons" \
        --verbose=default=4,macishtype=5 > "$1" 2>&1 &
    fcitx_pid=$!
    log_file="$1"
    shift
    if ISOLATED_FCITX5_LOG="$log_file" python3 "$0" "$@"; then
        status=0
    else
        status=$?
        echo "--- fcitx5 log tail ---" >&2
        tail -30 "$log_file" >&2
    fi
    # A restart hands over to a detached `fcitx5 -r` that neither
    # $fcitx_pid nor its process group reaches; left alone it exits only
    # when the bus goes away, saving into the scratch config while the
    # homes are being removed. Stop whoever owns the name instead and wait
    # for the name to drop, which follows that save.
    owner="$(dbus-send --session --print-reply --dest=org.freedesktop.DBus \
        / org.freedesktop.DBus.GetConnectionUnixProcessID \
        string:org.fcitx.Fcitx5 2>/dev/null | sed -n "s/.*uint32 //p")"
    kill "$fcitx_pid" 2>/dev/null
    wait "$fcitx_pid" 2>/dev/null
    if [ -n "$owner" ] && [ "$owner" != "$fcitx_pid" ]; then
        kill "$owner" 2>/dev/null
        i=0
        while [ "$i" -lt 100 ] && dbus-send --session --print-reply \
            --dest=org.freedesktop.DBus / org.freedesktop.DBus.NameHasOwner \
            string:org.fcitx.Fcitx5 2>/dev/null | grep -q "boolean true"; do
            i=$((i + 1))
            sleep 0.05
        done
    fi
    exit $status
' "$script_dir/TypingClient.py" "$log_file" "macishtype-$engine_id" "$@"
