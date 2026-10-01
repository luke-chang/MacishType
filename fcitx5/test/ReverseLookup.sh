#!/bin/sh
# Find Input Code (the reverseLookup capability): the status-area action / its
# hotkey reads the client's selection and shows each character's input codes in
# a read-only candidate window. Asserts the rendered content, cross-page
# navigation, the non-blocking fetch-backed prepare, idempotent re-prepare, the
# debounced idle release of the host-scoped index, and that a keystroke while
# the window is shown dismisses it without blocking composition.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
make -s -C "$root" dev-install > /dev/null

# Ctrl+Alt+L reaches the engine as keysym 'l' (0x6c = 108) with Ctrl+Alt
# (state 12); fcitx normalizes that to the configured Control+Alt+L. Escape is
# 65307, PageDown 65366 (matching Navigation.sh).
hotkey=108:46:12
# The window for a 甲 selection, drawn once the fetch-backed prepare resolves.
shown='waitevent:1:"text": "甲 ab'

check() {
    if printf '%s\n' "$2" | grep -qF "$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        printf '%s\n' "$2" | tail -20 >&2
        exit 1
    fi
}

check_re() {
    if printf '%s\n' "$2" | grep -qE "$3"; then
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

# The last candidate frame reflects the final window state.
last_cand() { printf '%s\n' "$1" | grep '"event": "candidates"' | tail -1; }
# The candidate frame that carries a given substring (e.g. a specific page).
frame_with() {
    printf '%s\n' "$1" | grep '"event": "candidates"' | grep -F "$2" | tail -1
}
line_of() { grep -nF "$2" "$1" | head -1 | cut -d: -f1; }

# --- Content, layout, and cross-page navigation (fetch-backed prepare) ------
# reverselookupfixture selects 甲乙丙; pageSize 2, so 甲乙 fill page 1 and 丙
# spills to page 2. 甲 carries a plain code plus an annotated one, 乙 has none,
# 丙 has 14 codes (over the per-character cap).
log=/tmp/fcitx5-macishtype-reverselookup.log
out="$(ISOLATED_LOG="$log" "$root/test/Isolated.sh" reverselookupfixture \
    setsurrounding:甲乙丙 "$hotkey" "$shown" 65366:117 \
    'waitevent:1:"text": "丙 ')"

check "a character's codes render, the annotated one parenthesized" \
    "$out" '"text": "甲 ab  cd (alt)"'
check "a character with no codes shows the em-dash placeholder" \
    "$out" '"text": "乙 —"'
# 丙's 14 codes are capped at 12 (c0..cB) and elided with an ellipsis.
check "an over-long code list is truncated with an ellipsis" \
    "$out" 'cB  …'
check_absent "codes past the per-character cap are dropped" \
    "$out" 'cC'
# The window is vertical and stays suspended (cursor -1, never highlighted).
check "the reverse window is vertical and suspended" \
    "$out" '"cursor": -1, "layout": 1'

page1="$(frame_with "$out" '甲 ab')"
check "page 1 advertises a next page" "$page1" '"hasNext": true'
check "page 1 has no previous page" "$page1" '"hasPrev": false'
page2="$(frame_with "$out" '丙 ')"
check "page 2 advertises a previous page" "$page2" '"hasPrev": true'

# The hotkey is consumed on a capability engine (contrast with the no-op case).
check "the hotkey is consumed on a capability engine" \
    "$out" '"keyval": 108, "handled": true'

# --- Non-blocking prepare: the fetched index resolves off the main loop ------
# A loading hint shows first (the fetch has not settled synchronously), then
# the per-character lookups run only after prepare's promise resolves.
check_re "a loading hint shows while the fetched index resolves" \
    "$out" '"auxUp": "(載入中…|Loading…)"'
built="$(line_of "$log" 'revfix prepare:built')"
lookup="$(line_of "$log" 'revfix lookup:甲')"
if [ -n "$built" ] && [ -n "$lookup" ] && [ "$built" -lt "$lookup" ]; then
    echo "PASS: per-character lookups run after the fetched index resolves"
else
    echo "FAIL: per-character lookups run after the fetched index resolves" >&2
    grep -nE 'revfix' "$log" >&2
    exit 1
fi

# --- Idempotent re-prepare: a second trigger reuses the built index ----------
idem_log=/tmp/fcitx5-macishtype-reverselookup-idem.log
ISOLATED_LOG="$idem_log" "$root/test/Isolated.sh" reverselookupfixture \
    setsurrounding:甲 "$hotkey" "$shown" "$hotkey" \
    'waitlog:1:revfix prepare:cached' > /dev/null
built_count="$(grep -c 'revfix prepare:built' "$idem_log" || true)"
cached_count="$(grep -c 'revfix prepare:cached' "$idem_log" || true)"
if [ "$built_count" = "1" ] && [ "$cached_count" -ge 1 ]; then
    echo "PASS: a re-triggered lookup reuses the built index (no rebuild)"
else
    echo "FAIL: a re-triggered lookup reuses the built index" >&2
    grep -nE 'revfix' "$idem_log" >&2
    exit 1
fi

# --- Debounced idle release of the host-scoped index -------------------------
# Left idle past the (test-shortened) grace period, the host calls the engine's
# static endReverseLookup.
rel_log=/tmp/fcitx5-macishtype-reverselookup-release.log
MACISHTYPE_REVERSE_LOOKUP_RELEASE_MS=200 ISOLATED_LOG="$rel_log" \
    "$root/test/Isolated.sh" reverselookupfixture \
    setsurrounding:甲 "$hotkey" "$shown" switchim:keyboard-us \
    'waitlog:1:revfix end' > /dev/null
if grep -qF 'revfix end' "$rel_log"; then
    echo "PASS: the host releases the reverse index after an idle grace period"
else
    echo "FAIL: the host releases the reverse index after an idle grace period" >&2
    grep -nE 'revfix' "$rel_log" >&2
    exit 1
fi

# Re-activating within the grace period cancels the release (no churn): with a
# longer window, switching away and back before it elapses must not release.
debounce_log=/tmp/fcitx5-macishtype-reverselookup-debounce.log
MACISHTYPE_REVERSE_LOOKUP_RELEASE_MS=600 ISOLATED_LOG="$debounce_log" \
    "$root/test/Isolated.sh" reverselookupfixture \
    setsurrounding:甲 "$hotkey" "$shown" switchim:keyboard-us sleep:300 \
    switchim:macishtype-reverselookupfixture sleep:800 > /dev/null
if grep -qF 'revfix end' "$debounce_log"; then
    echo "FAIL: re-activation within the grace period cancels the release" >&2
    grep -nE 'revfix' "$debounce_log" >&2
    exit 1
else
    echo "PASS: re-activation within the grace period cancels the release"
fi

# --- Dismissal: Escape closes with nothing committed ------------------------
escaped="$("$root/test/Isolated.sh" reverselookupfixture \
    setsurrounding:甲 "$hotkey" "$shown" 65307:9)"
check_absent "Escape dismisses the window without committing" \
    "$escaped" '"event": "commit"'
check "the candidate window is cleared after Escape" \
    "$(last_cand "$escaped")" '"items": []'

# --- Typing is never blocked: a normal key dismisses and then composes -------
typed="$("$root/test/Isolated.sh" reverselookupfixture \
    setsurrounding:甲 "$hotkey" "$shown" 97:38)"
check "a keystroke while shown dismisses and composes (not blocked)" \
    "$typed" '{"event": "commit", "text": "Z"}'

# --- Empty selection teaches the operation ----------------------------------
hint="$("$root/test/Isolated.sh" reverselookupfixture "$hotkey")"
check_re "an empty selection shows the select-text hint on the aux line" \
    "$hint" '"auxUp": "(先選取文字再執行尋找輸入碼|Select text first, then run Find Input Code)"'

# An ASCII-only selection (letters, digits, whitespace) has nothing to look
# up — ASCII is typed directly — so it shows the same hint, not a window of
# dashes.
blank="$("$root/test/Isolated.sh" reverselookupfixture "setsurrounding:ab 12" \
    "$hotkey")"
check_re "an ASCII-only selection shows the select-text hint" \
    "$blank" '"auxUp": "(先選取文字再執行尋找輸入碼|Select text first, then run Find Input Code)"'

# A mixed selection looks up only its non-ASCII characters (the ASCII 'a'/'b'
# are dropped, so no dash rows for them).
mixed="$("$root/test/Isolated.sh" reverselookupfixture "setsurrounding:a甲b" \
    "$hotkey" "$shown")"
check "a mixed selection looks up its non-ASCII character" \
    "$mixed" '"text": "甲 ab  cd (alt)"'
check_absent "a mixed selection drops its ASCII characters" \
    "$mixed" '"text": "a '

# --- Multi-code-point clusters stay whole ------------------------------------
# ⚙︎ (U+2699 U+FE0E) yields one row for the full grapheme cluster — not a
# split gear plus an orphan variation selector. Built from explicit bytes:
# editors silently normalize variation sequences.
gear="$(printf '\342\232\231\357\270\216')"
cluster="$("$root/test/Isolated.sh" reverselookupfixture \
    "setsurrounding:a${gear}b" "$hotkey" "waitevent:1:\"text\": \"${gear} —\"")"
check "a variation sequence renders as one whole-cluster row" \
    "$cluster" "\"text\": \"${gear} —\""
check_absent "the cluster is not split at its variation selector" \
    "$cluster" '"text": "⚙ —"'

# --- Codes that are not plain strings ---------------------------------------
# 丁's list mixes an empty string, a number, null, an object with a number code
# and annotation, one with an empty code and one with no code; 戊's holds only
# an empty string. Codes read like candidate text, and empty ones drop.
odd="$("$root/test/Isolated.sh" reverselookupfixture "setsurrounding:丁戊" \
    "$hotkey" 'waitevent:1:"text": "丁 ')"
check "number codes and annotations stringify, and empty codes drop" \
    "$odd" '"text": "丁 5001  7 (8)"'
check "a character whose codes are all empty shows the em-dash placeholder" \
    "$odd" '"text": "戊 —"'

# --- No capability: the hotkey is inert -------------------------------------
# navfixture declares no reverseLookup capability, so the hotkey is not
# intercepted (forwarded, handled=false) and no reverse window opens.
noop="$("$root/test/Isolated.sh" navfixture setsurrounding:甲 "$hotkey")"
check "the hotkey is inert on an engine without the capability" \
    "$noop" '"keyval": 108, "handled": false'
check_absent "no reverse window opens without the capability" \
    "$noop" '先選取文字再執行尋找輸入碼'

echo "Reverse-lookup checks passed."
