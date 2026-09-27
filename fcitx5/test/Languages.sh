#!/bin/sh
# The session's locale environment as engines see it. glibc and gettext name
# a script, and sometimes a variant, with a modifier (sr_RS@latin), and a few
# glibc locales are written in a script CLDR does not give their language
# and region (sr_ME is Cyrillic); both become BCP 47 subtags, and the script
# stays only where the language and region do not already imply it. What
# jshost does with any tag list is in jshost/tests/RunContractTests.py, which
# does NOT parse this file (each run sets its own locale environment).
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null
log=/tmp/fcitx5-macishtype-languages.log

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -20 >&2
        exit 1
    fi
}

# LC_ALL and LC_MESSAGES read as C so only the variables under test count.
run() {
    env "$@" LC_ALL=C LC_MESSAGES=C ISOLATED_LOG="$log" \
        "$root/test/Isolated.sh" langfixture > /dev/null
    cat "$log"
}

modifiers="$(run LANGUAGE="sr_RS@latin:uz_UZ@cyrillic:sr_ME:sr@ijekavianlatin:ca_ES@valencia" LANG=C)"
lang_form="$(run -u LANGUAGE LANG=sr_RS.UTF-8@latin)"

check "modifiers and glibc's own scripts become subtags, kept where not implied" \
    "$modifiers" \
    'langfx languages ["sr-Latn-RS","sr","uz-Cyrl-UZ","uz","sr-Cyrl-ME","sr-Latn-ijekavsk","ca-ES-valencia","ca"]'
check "Intl defaults to the preferred language, script included" \
    "$modifiers" 'langfx intl sr-Latn-RS'
check "a modifier after the codeset, as LANG spells it, still counts" \
    "$lang_form" 'langfx languages ["sr-Latn-RS","sr"]'
echo "Language checks passed."
