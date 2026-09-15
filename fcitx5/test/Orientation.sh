#!/bin/sh
# Candidate orientation. When the manifest does not fix
# candidateWindow.layoutDirection, the addon auto-generates a per-input-method
# orientation setting (macOS parity: showDirection = manifest omits it). The
# choice drives the candidate window's layout hint; "system" follows the fcitx
# global (classicui's "Vertical Candidate List"), horizontal when unreadable.
# When the manifest does fix the direction, the setting stays hidden.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

# Labels resolve against the daemon's locale; pin it so assertions hold.
# LC_ALL as well: gettext ignores LANGUAGE under the C locale, which is what
# an ssh session without LANG gets.
export LANGUAGE="zh_TW:en" LC_ALL=zh_TW.UTF-8

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

# layoutfixture declares no layoutDirection, so the picker is generated; KeyA
# (97:38) shows candidates whose layout hint reflects the choice.
present="$("$root/test/Isolated.sh" layoutfixture getconfig)"
default_layout="$("$root/test/Isolated.sh" layoutfixture 97:38)"
cfg="$(mktemp -d)"
vertical_layout="$(ISOLATED_CONFIG_HOME="$cfg" "$root/test/Isolated.sh" \
    layoutfixture setconfig:orientation=vertical refocus 97:38)"
rm -rf "$cfg"
# fixture fixes layoutDirection, so the picker is suppressed even though the
# engine stays configurable through its other settings.
absent="$("$root/test/Isolated.sh" fixture getconfig)"

check "a manifest without layoutDirection generates the orientation picker" \
    "$present" '"Enum": {"0": "system", "1": "horizontal", "2": "vertical"'
check "the orientation picker carries localized labels" \
    "$present" '"EnumI18n": {"0": "跟隨系統預設", "1": "水平", "2": "垂直"}'
# Layout hint ints: 1 = vertical, 2 = horizontal (fcitx CandidateLayoutHint).
check "the default follows the system global, horizontal when unset" \
    "$default_layout" '"layout": 2'
check "choosing vertical flips the candidate layout hint" \
    "$vertical_layout" '"layout": 1'
check "a fixed manifest direction keeps the engine configurable otherwise" \
    "$absent" '"Enum": {"0": "alpha"'
check_absent "a fixed manifest direction suppresses the orientation picker" \
    "$absent" '"orientation"'
echo "Orientation checks passed."
