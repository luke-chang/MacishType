#!/bin/sh
# Navigating from a suspended candidate highlight (MacishType parity): the
# first arrow/item key only reveals the first candidate without moving, while
# page keys and Home/End navigate immediately (treating suspended as index 0).
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$MACISHTYPE_TEST_INSTALLED" ] || make -s -C "$root" dev-install > /dev/null

# navfixture: KeyA=97:38 shows c0..c8 suspended, pageSize 3 (3 pages).
# PageDown=65366:117, ArrowDown=65364:116.
paged="$("$root/test/Isolated.sh" navfixture 97:38 65366:117)"
revealed="$("$root/test/Isolated.sh" navfixture 97:38 65364:116)"

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

# The candidate frame reflecting the final state (page indicators appear on
# every frame, so assertions about the end state must read the last one).
last_cand() { printf '%s\n' "$1" | grep '"event": "candidates"' | tail -1; }

# Page key jumps to the next page (c3 is the first candidate of page 2).
check "a page key navigates to the next page from a suspended highlight" \
    "$paged" '"text": "c3"'
# Arrow key only reveals the first candidate: stays on page 1, no c3.
check_absent "an arrow key does not page from a suspended highlight" \
    "$revealed" '"text": "c3"'
check "an arrow key reveals the first candidate (cursor 0) from suspended" \
    "$revealed" '"text": "c2"}], "cursor": 0'

# --- Native pagination: page indicators, cross-page nav, absolute mapping ---
# KeyB=98:56 opens with initialHighlight 5 (c5, page 2). PageUp=65365:112,
# Home=65360:110, End=65367:115, digit2=50:11.
page1="$("$root/test/Isolated.sh" navfixture 97:38)"
onpage2="$("$root/test/Isolated.sh" navfixture 98:56)"
pageupped="$("$root/test/Isolated.sh" navfixture 97:38 65366:117 65365:112)"
ended="$("$root/test/Isolated.sh" navfixture 97:38 65367:115)"
homed="$("$root/test/Isolated.sh" navfixture 98:56 65360:110)"
committed="$("$root/test/Isolated.sh" navfixture 97:38 65366:117 50:11)"

# Page 1 advertises a next page and no previous page (drives the native
# down arrow — the whole point of the migration).
check "page 1 has a next page and no previous page" \
    "$(last_cand "$page1")" '"hasPrev": false, "hasNext": true'
check "page 2 has a previous page" \
    "$(last_cand "$paged")" '"hasPrev": true'
# initialHighlight past page 0 opens on the highlight's page (setPage guard).
check "initialHighlight past page 0 opens the highlighted candidate's page" \
    "$(last_cand "$onpage2")" '"text": "c5"}], "cursor": 2'
check "initialHighlight past page 0 marks the previous page" \
    "$(last_cand "$onpage2")" '"hasPrev": true'
# PageUp returns to the first page and clears the previous-page flag.
check "PageUp returns to the first page" \
    "$(last_cand "$pageupped")" '"text": "c0"'
check "PageUp clears the previous-page flag" \
    "$(last_cand "$pageupped")" '"hasPrev": false'
# End / Home move within the current page (horizontal layout).
check "End selects the last candidate of the page (cursor 2)" \
    "$(last_cand "$ended")" '"text": "c2"}], "cursor": 2'
check "Home selects the first candidate of the page (cursor 0)" \
    "$(last_cand "$homed")" '"text": "c5"}], "cursor": 0'
# An index label on page 2 commits the correct absolute candidate.
check "an index label on page 2 commits the absolute candidate c4" \
    "$committed" '{"event": "commit", "text": "c4"}'

# --- commitSelectedCandidate without a highlight / without a window ---
# Enter on a suspended highlight is an empty commit: the host never picks a
# candidate; with no engine candidateConfirmed the fallback just ends the
# composition. Return=65293:36; KeyC=99:54 fires commitSelectedCandidate
# with no window up, which must be a silent no-op.
entered="$("$root/test/Isolated.sh" navfixture 97:38 65293:36)"
nowindow="$("$root/test/Isolated.sh" navfixture 99:54)"

check_absent "Enter on a suspended highlight commits nothing" \
    "$entered" '"event": "commit"'
check "Enter on a suspended highlight dismisses the window" \
    "$(last_cand "$entered")" '"items": []'
check "commitSelectedCandidate with no window is still consumed" \
    "$nowindow" '"keyval": 99, "handled": true'
check_absent "commitSelectedCandidate with no window commits nothing" \
    "$nowindow" '"event": "commit"'

# --- Engine-driven navigation (macOS-parity hostglue helpers) ---
# intentfixture opts out of handleNavigationKeys/handleIndexLabelKeys and
# replays navigationIntent()/candidateIndex() itself. Tab=65289:23,
# Shift+Tab=65056:23:1, Alt+Down=65364:116:8, Shift+Down=65364:116:1,
# ArrowRight=65363:114, space=32:65.
moved="$("$root/test/Isolated.sh" intentfixture 97:38 65363:114)"
altdown="$("$root/test/Isolated.sh" intentfixture 97:38 65364:116:8)"
shiftdown="$("$root/test/Isolated.sh" intentfixture 97:38 65364:116:1)"
wrapfwd="$("$root/test/Isolated.sh" intentfixture 97:38 65366:117 65366:117 65289:23)"
wrapback="$("$root/test/Isolated.sh" intentfixture 97:38 65056:23:1)"
lastpage="$("$root/test/Isolated.sh" intentfixture 97:38 65366:117 65366:117 50:11)"
spaced="$("$root/test/Isolated.sh" intentfixture 97:38 32:65)"

check "navigationIntent drives an arrow through navigateCandidates" \
    "$(last_cand "$moved")" '"text": "c2"}], "cursor": 1'
check "Option disqualifies a navigation key" \
    "$altdown" '"keyval": 65364, "handled": false'
check "Shift disqualifies a non-Tab navigation key" \
    "$shiftdown" '"keyval": 65364, "handled": false'
check "Tab wraps forward from the last candidate to the first" \
    "$(last_cand "$wrapfwd")" '"text": "c2"}], "cursor": 0'
check "Shift+Tab wraps backward from the first candidate to the last" \
    "$(last_cand "$wrapback")" '"text": "c6"'
check "candidateIndex answers within pageSize on a short last page" \
    "$lastpage" '{"event": "commit", "text": "ci1"}'
check "whitespace input never matches an index label" \
    "$spaced" '"keyval": 32, "handled": false'

# --- Index labels and the page range on a short last page ---
# pagerangefixture: KeyA=97:38 shows c0..c6 with pageSize 3, so the last page
# holds one candidate and two empty label slots. KeyZ=122:52 logs the range
# the labels address. One run covers every case, in order: the range with no
# window, the range on a full first page, the range on the short last page
# (after PageDown twice), Digit2=50:11 landing on an empty slot, and
# Digit1=49:10 addressing the one candidate there is.
range_log=/tmp/fcitx5-macishtype-nav-pagerange.log
pagerange="$(ISOLATED_LOG="$range_log" "$root/test/Isolated.sh" \
    pagerangefixture 122:52 97:38 122:52 65366:117 65366:117 122:52 \
    50:11 49:10)"
ranges="$(cat "$range_log")"

check "the page range is empty with no candidate window" \
    "$ranges" 'cw-range start=0 end=0 visible=false'
check "the page range covers a full first page" \
    "$ranges" 'cw-range start=0 end=3 visible=true'
check "the page range stops at the last candidate on a short page" \
    "$ranges" 'cw-range start=6 end=7 visible=true'
check "an index label with nothing behind it reaches the engine" \
    "$pagerange" '"keyval": 50, "handled": false'
check "an index label addressing a candidate commits it" \
    "$pagerange" '{"event": "commit", "text": "c6"}'
echo "Navigation checks passed."
