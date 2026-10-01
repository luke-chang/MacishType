#!/bin/sh
# Manifest settings become a per-IM fcitx configuration: the DBus
# description carries the schema (tags as enum values, localized labels),
# gated system fields stay out of both the description and the pushed
# values, values persist as ini, and — matching the contract and the
# macOS host — a change applies only at the next session boundary, never
# mid-composition.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

# Labels resolve against the daemon's locale; pin it so assertions hold
# everywhere.
export LANGUAGE="zh_TW:en"

config_home="$(mktemp -d)"
log1=/tmp/fcitx5-macishtype-settings1.log
log2=/tmp/fcitx5-macishtype-settings2.log
log3=/tmp/fcitx5-macishtype-settings3.log
trap 'rm -rf "$config_home"' EXIT

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
        exit 1
    else
        echo "PASS: $1"
    fi
}

# Run 1: schema description, initial push, mid-session safety, persistence.
out1="$(ISOLATED_LOG="$log1" ISOLATED_CONFIG_HOME="$config_home" \
    "$root/test/Isolated.sh" fixture \
    getconfig setconfig:mode=alpha sleep:300)"
log1content="$(cat "$log1")"

check "description carries picker tags as enum values" "$out1" '"Enum": {"0": "alpha"'
check "description carries localized enum labels" "$out1" '"EnumI18n": {"0": "甲模式"'
check_absent "gated system field stays out of the description" "$out1" 'enableAssociatedMode'
check "initial push resolves picker token to its value" "$log1content" \
    'settings {"flag":true,"note":"hello","mode":{"kind":"b"}}'
check_absent "gated system field is not pushed" "$log1content" '"enableAssociatedMode"'
check_absent "a mid-session config change does not disturb the session" \
    "$log1content" 'settings-changed'
check "the changed value persists as ini" \
    "$(cat "$config_home/fcitx5/macishtype/fixture.conf")" 'mode=alpha'

# Run 2: the change takes effect at the next activate boundary (refocus).
ISOLATED_LOG="$log2" ISOLATED_CONFIG_HOME="$(mktemp -d)" \
    "$root/test/Isolated.sh" fixture \
    setconfig:mode=alpha refocus 'waitlog:1:settings-changed' > /dev/null
check "the change applies at the next activate, not before" "$(cat "$log2")" \
    'settings-changed {"flag":true,"note":"hello","mode":{"kind":"a"}}'

# Run 3: a fresh daemon over the persisted config starts from the new value.
ISOLATED_LOG="$log3" ISOLATED_CONFIG_HOME="$config_home" \
    "$root/test/Isolated.sh" fixture > /dev/null
check "persisted values apply on the next load" "$(cat "$log3")" \
    'settings {"flag":true,"note":"hello","mode":{"kind":"a"}}'

echo "Settings checks passed."
