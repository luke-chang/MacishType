#!/bin/sh
# Manifest menu, the fcitx5 UI half, driven through an impersonated kimpanel
# panel — the only route to status-area actions in the headless harness
# (notificationitem needs classicui, which Isolated.sh disables; no fcitx5
# DBus interface can trigger a status action). Asserts the composed property
# list (declaration order, dividers and hidden/disabled items absent on
# kimpanel), the checked-state icon, TriggerProperty reaching the engine as
# a keyless menuchange, and value persistence across daemons. Assertions
# grep only action names: kimpanel's property format is colon-separated and
# labels are locale-dependent.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

log=/tmp/fcitx5-macishtype-menuui.log
confhome="$(mktemp -d)"
trap 'rm -rf "$confhome"' EXIT

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

# The property format is name:label:icon:longText:special; labels are
# locale-dependent, so icon assertions match [^:"]* through the label.
check_re() {
    if printf '%s\n' "$2" | grep -qE "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -20 >&2
        exit 1
    fi
}

# Asserts that every named action appears in the given order within one
# properties dump (the payload is an ordered array, so index comparison is
# the assertion).
check_order() {
    desc="$1"
    props="$2"
    shift 2
    if printf '%s\n' "$props" | python3 -c '
import json, sys
wanted = sys.argv[1:]
items = json.loads(sys.stdin.read())["items"]
names = [entry.split(":", 1)[0].removeprefix("/Fcitx/") for entry in items]
try:
    positions = [names.index(name) for name in wanted]
except ValueError as missing:
    print(f"absent: {missing}", file=sys.stderr)
    sys.exit(1)
sys.exit(0 if positions == sorted(positions) else 1)
' "$@"; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc" >&2
        printf '%s\n' "$props" >&2
        exit 1
    fi
}

# TriggerProperty defers the activate on a 30ms TimeEvent (kimpanel waits
# for the ic to take focus), but its zero accuracy lets sd-event coalesce
# it onto a 250ms grid, so a flip can land ~280ms after the trigger. Each
# flip is awaited through its menuchange line; the 300ms sleep then only
# covers the UI flush and the RegisterProperties re-send.
out="$(ISOLATED_LOG="$log" ISOLATED_CONFIG_HOME="$confhome" \
    "$root/test/Isolated.sh" menufixture --kimpanel \
    sleep:300 props \
    trigger:macishtype-menu-menufixture-2 'waitlog:1:menufx menuchange' \
    trigger:macishtype-menu-menufixture-0 'waitlog:2:menufx menuchange' \
    sleep:300 props)"
logtext="$(cat "$log")"

props1="$(printf '%s\n' "$out" | grep -F '"seq": 1' || true)"
props2="$(printf '%s\n' "$out" | grep -F '"seq": 2' || true)"

check "the panel impersonation came up" "$out" '"event": "kimpanel", "ready": true'
check "the first toggle is composed" "$props1" \
    'macishtype-menu-menufixture-0:'
check_order "custom items follow the capability entry, in declared order" \
    "$props1" macishtype-find-input-code \
    macishtype-menu-menufixture-0 macishtype-menu-menufixture-2 \
    macishtype-menu-menufixture-4
check "the second toggle is composed" "$props1" \
    'macishtype-menu-menufixture-2:'
check "the hidden-condition toggle is composed while its condition is false" \
    "$props1" 'macishtype-menu-menufixture-4:'
check_absent "dividers are not composed on kimpanel" "$props1" \
    'macishtype-menu-menufixture-1:'
check_absent "dividers are not composed on kimpanel (second divider)" \
    "$props1" 'macishtype-menu-menufixture-3:'
check_re "an unchecked toggle carries the empty-checkbox icon" "$props1" \
    'macishtype-menu-menufixture-0:[^:"]*:checkbox-symbolic:'
check_re "a default-true toggle starts checked (icon present)" "$props1" \
    'macishtype-menu-menufixture-2:[^:"]*:checkbox-checked-symbolic:'

check "the first flip reaches the engine as a keyless menuchange" \
    "$logtext" \
    'menufx menuchange key=undefined strict=false verbose=false extra=false'
check "the second flip reads the first one's value back" "$logtext" \
    'menufx menuchange key=undefined strict=true verbose=false extra=false'

check_re "the flipped toggle now carries the checked icon" "$props2" \
    'macishtype-menu-menufixture-0:[^:"]*:checkbox-checked-symbolic:'
check_absent "a disabledWhen-true toggle is not composed" "$props2" \
    'macishtype-menu-menufixture-2:'

# Same config home, fresh daemon: flipped values persist; a settings write
# plus the refocus session boundary hides the conditioned toggle.
out2="$(ISOLATED_LOG="$log" ISOLATED_CONFIG_HOME="$confhome" \
    "$root/test/Isolated.sh" menufixture --kimpanel \
    "setconfig:hideExtras=True" refocus sleep:300 props)"
logtext2="$(cat "$log")"

check "flipped values persist across daemons" "$logtext2" \
    'menufx eval keys=["strictMode","verboseHints","extraPanel"] strict=true verbose=false extra=false undeclared=undefined'
props21="$(printf '%s\n' "$out2" | grep -F '"seq": 1' || true)"
check "the composed list survives the settings write" "$props21" \
    'macishtype-menu-menufixture-0:'
check_absent "hiddenWhen via settings drops the toggle from the surface" \
    "$props21" 'macishtype-menu-menufixture-4:'

# Hot reload rebuilds the per-engine actions (destroy-then-create, so a
# duplicate registerAction would leave them nameless and unreachable) and
# re-seeds the values from the ini. Served from a writable user layer so
# the manifest can be touched mid-run, like Reload.sh.
reload_config="$(mktemp -d)"
reload_data="$(mktemp -d)"
trap 'rm -rf "$confhome" "$reload_config" "$reload_data"' EXIT
reload_fixture="$reload_data/fcitx5/macishtype/engines/menufixture"
mkdir -p "$reload_fixture"
cp "$root/test/fixtures/share/fcitx5/macishtype/engines/menufixture/"* \
    "$reload_fixture/"

wait_for_log() {
    i=0
    while [ "$i" -lt 300 ]; do
        if grep -qF "$1" "$log"; then
            return 0
        fi
        if ! kill -0 "$client" 2>/dev/null; then
            break
        fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "FAIL: timed out waiting for: $1" >&2
    tail -20 "$log" >&2
    kill "$client" 2>/dev/null
    exit 1
}

# The flip is saved before the engine hears of it, so once its menuchange
# is logged, the reload re-seeds the flipped value.
: > "$log"
out3="$(
    ISOLATED_LOG="$log" ISOLATED_CONFIG_HOME="$reload_config" \
        ISOLATED_DATA_HOME="$reload_data" \
        "$root/test/Isolated.sh" menufixture --kimpanel \
        sleep:300 trigger:macishtype-menu-menufixture-0 \
        'waitlog:2:Engine loaded: menufixture' sleep:300 props &
    client=$!
    wait_for_log 'menufx menuchange'
    printf '\n' >> "$reload_fixture/manifest.json"
    wait $client
)"
logtext3="$(cat "$log")"

check "the manifest edit reloads the engine" "$logtext3" \
    'Engine changed on disk, reloading: menufixture'
check "the flipped value survives the reload" "$logtext3" \
    'menufx eval keys=["strictMode","verboseHints","extraPanel"] strict=true verbose=true extra=false undeclared=undefined'
props31="$(printf '%s\n' "$out3" | grep -F '"seq": 1' || true)"
check "the rebuilt actions are still addressable" "$props31" \
    'macishtype-menu-menufixture-0:'
check_re "the rebuilt action still reflects the flipped state" "$props31" \
    'macishtype-menu-menufixture-0:[^:"]*:checkbox-checked-symbolic:'
echo "MenuUi checks passed."
