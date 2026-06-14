// Array30 (行列) engine on the JavaScript engine path.
//
// Composing: markedText is the radical readout; the window previews short codes
// for 1-2 keys or main-table candidates for 3+ keys. Space resolves the code
// into candidate-selection; `'` resolves it against the phrase table instead.
// Also: `?`/`*` wildcard query, `w`/`hg` symbol groups, Option+key full-width.

const SELECTION_KEYS = "1234567890";
// Array codes are at most 5 keys; the 5th is always the "i" disambiguation key.
const MAX_CODE_LENGTH = 5;
const DISAMBIGUATION_KEY = "i";
// Cap on wildcard results so a broad pattern (e.g. "a*") stays cheap.
const WILDCARD_LIMIT = 200;

// Composition key -> radical-code label for the marked text.
const KEYNAME = new Map(Object.entries({
  a: "1-", b: "5⇣", c: "3⇣", d: "3-", e: "3⇡", f: "4-", g: "5-", h: "6-",
  i: "8⇡", j: "7-", k: "8-", l: "9-", m: "7⇣", n: "6⇣", o: "9⇡", p: "0⇡",
  q: "1⇡", r: "4⇡", s: "2-", t: "5⇡", u: "7⇡", v: "4⇣", w: "2⇡", x: "2⇣",
  y: "6⇡", z: "1⇣", ".": "9⇣", "/": "0⇣", ";": "0-", ",": "8⇣",
  "?": "？", "*": "＊",
}));
// `event.code` (US-QWERTY physical position) → Array key, so composition is
// keyboard-layout-independent. Letters derive from the name ("KeyA" -> "a").
function arrayKeyForCode(code) {
  switch (code) {
    case "Comma": return ",";
    case "Period": return ".";
    case "Slash": return "/";
    case "Semicolon": return ";";
    default:
      // "KeyA".."KeyZ" → "a".."z"
      return code.length === 4 && code.startsWith("Key")
        && code[3] >= "A" && code[3] <= "Z"
        ? code[3].toLowerCase()
        : null;
  }
}

// Symbol-group names, shown in the group menu at a symbol prefix.
const GROUP_NAMES = {
  w0: "注音符號組", w1: "標點符號組", w2: "括號符號組", w3: "一般符號組",
  w4: "數學符號組", w5: "方向符號組", w6: "單位符號組", w7: "圖表符號組",
  w8: "順序符號組", w9: "希臘字母組",
  hg0: "康熙部首組", hg1: "標誌符號組", hg2: "技術符號組",
  hg8: "表意描述符組", hg9: "筆畫組",
};

// Main table: code -> [char, ...]; rare chars are excluded unless the setting
// enables them.
let mainTable = new Map();
// Symbol groups: group code -> [symbol, ...]; rare-filtered like the main table.
let symbolTable = new Map();
// Short codes: code -> [{ label, value }, ...]; label is the fixed selection key.
let shortTable = new Map();
// Phrases: code -> [phrase, ...], looked up by the "'" key.
let phraseTable = new Map();
// Character frequency, used to rank wildcard results.
let frequencyTable = new Map();
// Symbol -> name, for symbol-group annotations.
let symbolNames = new Map();

// Iterate the data rows of a tab-separated table, skipping comment and blank
// lines and rows without a non-empty code and value.
function forEachRow(text, fn) {
  for (const rawLine of text.split(/\r?\n/)) {
    if (!rawLine || rawLine.startsWith("#")) continue;
    const fields = rawLine.split("\t");
    if (fields.length < 2 || !fields[0] || !fields[1]) continue;
    fn(fields);
  }
}

// Load code -> [value, ...] in file order; a non-empty third column marks a rare
// value, skipped unless includeRare.
function loadTable(text, table, includeRare = true) {
  forEachRow(text, ([code, value, flag]) => {
    if (flag && !includeRare) return;
    const list = table.get(code);
    if (list) list.push(value);
    else table.set(code, [value]);
  });
}

// Fetch an engine-folder file and hand its text to `onText`; log load failures.
function loadFile(filename, onText) {
  fetch(filename)
    .then((response) => response.text())
    .then(onText)
    .catch((error) => console.error(filename, "load failed:", error.message));
}

// (Re)load the main and symbol tables when the rare-characters setting changes.
let tablesIncludeRare = null;
function syncRareTables() {
  const includeRare = manifest.settings.showRareCharacters === true;
  if (includeRare === tablesIncludeRare) return;
  tablesIncludeRare = includeRare;
  loadFile("./Array30.txt", (text) => {
    const next = new Map();
    loadTable(text, next, includeRare);
    mainTable = next;
    console.info(
      "Array30.txt loaded:", mainTable.size, "codes",
      includeRare ? "(incl. rare)" : "(common only)"
    );
  });
  loadFile("./ArraySymbol.txt", (text) => {
    const next = new Map();
    loadTable(text, next, includeRare);
    symbolTable = next;
    console.info("ArraySymbol.txt loaded:", symbolTable.size, "groups");
  });
}
syncRareTables();
addEventListener("settingschange", syncRareTables);

loadFile("./ArrayShortCode.txt", (text) => {
  const next = new Map();
  forEachRow(text, ([codeWithSlot, value]) => {
    if (codeWithSlot.length < 2) return;
    const label = codeWithSlot[codeWithSlot.length - 1];
    const code = codeWithSlot.slice(0, -1);
    const list = next.get(code);
    if (list) list.push({ label, value });
    else next.set(code, [{ label, value }]);
  });
  shortTable = next;
  console.info("ArrayShortCode.txt loaded:", shortTable.size, "codes");
});

loadFile("./ArrayPhrase.txt", (text) => {
  const next = new Map();
  loadTable(text, next);
  phraseTable = next;
  console.info("ArrayPhrase.txt loaded:", phraseTable.size, "codes");
});

loadFile("./WordFrequency.zh-Hant.txt", (text) => {
  const next = new Map();
  forEachRow(text, ([char, count]) => {
    const freq = Number(count);
    if (!Number.isNaN(freq)) next.set(char, freq);
  });
  frequencyTable = next;
  console.info("WordFrequency.zh-Hant.txt loaded:", frequencyTable.size, "chars");
});

// Parsed directly, not via forEachRow: a symbol key can itself be "#".
loadFile("./SymbolNames.zh-Hant.txt", (text) => {
  for (const line of text.split(/\r?\n/)) {
    const tab = line.indexOf("\t");
    if (tab < 0) continue;
    symbolNames.set(line.slice(0, tab), line.slice(tab + 1));
  }
  console.info("SymbolNames.zh-Hant.txt loaded:", symbolNames.size, "names");
});

function radicalReadout(code) {
  return [...code].map((char) => KEYNAME.get(char) ?? char).join("");
}

// Convert an ASCII printable char to its full-width form (space -> U+3000).
function toFullwidth(char) {
  if (!char || char.length !== 1) return null;
  if (char === " ") return "　";
  const code = char.charCodeAt(0);
  if (code < 0x21 || code > 0x7e) return null;
  return String.fromCharCode(code + 0xfee0);
}

function shortCodeView(code) {
  const entries = shortTable.get(code) ?? [];
  return {
    candidates: entries.map((entry) => entry.value),
    indexLabels: entries.map((entry) => entry.label).join(""),
  };
}

function hasWildcard(code) {
  return code.includes("?") || code.includes("*");
}

// A symbol prefix is a code a digit extends into a group (only "w" / "hg").
function isSymbolPrefix(code) {
  if (!code) return false;
  for (const digit of SELECTION_KEYS) {
    if (symbolTable.has(code + digit)) return true;
  }
  return false;
}

// Positional wildcard pattern: ? = one key, * = one or more keys.
function wildcardRegex(pattern) {
  let source = "^";
  for (const char of pattern) {
    if (char === "?") source += ".";
    else if (char === "*") source += ".+";
    else source += char.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(source + "$");
}

// Wildcard query against the main table. A leading "*" with no other wildcard
// matches any code containing all the given radicals (any order, extras
// allowed); otherwise ?/* match by position. Deduped by char, ranked by
// frequency, capped, and annotated with the matched code's radical readout.
function wildcardMatches(pattern) {
  let matches;
  if (pattern.startsWith("*") && !hasWildcard(pattern.slice(1))) {
    const required = [...pattern.slice(1)];
    matches = (code) => required.every((radical) => code.includes(radical));
  } else {
    const regex = wildcardRegex(pattern);
    matches = (code) => regex.test(code);
  }

  const found = [];
  const seen = new Set();
  for (const [code, chars] of mainTable) {
    if (!matches(code)) continue;
    for (const char of chars) {
      if (seen.has(char)) continue;
      seen.add(char);
      found.push({ char, code });
    }
  }

  // Stable sort by frequency keeps common chars above the WILDCARD_LIMIT cap.
  found.sort(
    (a, b) => (frequencyTable.get(b.char) ?? 0) - (frequencyTable.get(a.char) ?? 0)
  );
  return found.slice(0, WILDCARD_LIMIT).map(({ char, code }) => ({
    candidate: char,
    annotation: radicalReadout(code),
  }));
}

/** @typedef {import("../Utils/MacishType").InputEngine} InputEngine */
/** @typedef {import("../Utils/MacishType").KeyEvent} KeyEvent */
/** @typedef {import("../Utils/MacishType").ConfirmEvent} ConfirmEvent */

/** @implements {InputEngine} */
export default class ArrayEngine {
  constructor() {
    this.reset();
  }

  // Host-facing notification: composition ended (in-app commit or deactivate).
  compositionEnded() {
    this.reset();
  }

  // Internal helper, also called throughout handleKey / enterSelecting.
  reset() {
    this.code = "";
    // false = composing, true = candidate-selection (entered by Space).
    this.selecting = false;
    // In a symbol group: Space pages instead of committing.
    this.symbolGroup = false;
    // In the symbol-prefix group menu: picking a candidate opens a group.
    this.groupMenu = false;
  }

  /** @param {KeyEvent} event */
  handleKey(event) {
    if (event.isComposing) {
      if (hasWildcard(this.code)) return this.handleWildcardKey(event);
      return this.selecting
        ? this.handleSelectingKey(event)
        : this.handleComposingKey(event);
    }

    const composed = this.compositionChar(event);
    if (composed) {
      this.code = composed;
      this.render(event);
      return true;
    }
    const wild = this.wildcardChar(event);
    if (wild) {
      this.code = wild;
      this.renderWildcard(event);
      return true;
    }
    // Option + printable: commit its full-width form (layout-aware).
    if (event.altKey && !event.metaKey && !event.ctrlKey) {
      const fullwidth = toFullwidth(event.keyIgnoringModifiers);
      if (fullwidth) {
        event.flushStaged(fullwidth);
        return true;
      }
    }
    return false;
  }

  // Paging: = / ] / Shift+→ forward, - / [ / Shift+← back (no wrap), while the
  // window is visible. Brackets / equal require no shift (Shift+= is "+").
  /** @param {KeyEvent} event */
  pageKey(event) {
    if (!event.candidateWindow.isVisible) return false;
    if (event.metaKey || event.ctrlKey || event.altKey) return false;
    const shift = event.shiftKey;
    if ((event.code === "Equal" || event.code === "BracketRight") && !shift) {
      event.navigateCandidates("pageForward");
      return true;
    }
    if ((event.code === "Minus" || event.code === "BracketLeft") && !shift) {
      event.navigateCandidates("pageBackward");
      return true;
    }
    if (event.code === "ArrowRight" && shift) {
      event.navigateCandidates("pageForward");
      return true;
    }
    if (event.code === "ArrowLeft" && shift) {
      event.navigateCandidates("pageBackward");
      return true;
    }
    return false;
  }

  // No Cmd/Ctrl/Option/Shift, so a control key may perform its action.
  /** @param {KeyEvent} event */
  isBareKey(event) {
    return !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;
  }

  /** @param {KeyEvent} event */
  handleComposingKey(event) {
    if (this.pageKey(event)) return true;
    if (this.isBareKey(event)) {
      switch (event.code) {
        case "Escape":
          this.reset();
          event.resetContext();
          return true;
        case "Backspace":
          this.code = this.code.slice(0, -1);
          if (this.code) {
            this.render(event);
          } else {
            this.reset();
            event.resetContext();
          }
          return true;
        case "Space":
          this.enterSelecting(event, mainTable.get(this.code) ?? []);
          return true;
        case "Quote":
          // The "'" key resolves against the phrase table instead.
          this.enterSelecting(event, phraseTable.get(this.code) ?? []);
          return true;
      }
    }
    // Wildcard key extends by symbol, composition key by position.
    const wild = this.wildcardChar(event);
    if (wild) {
      if (this.canExtendWildcard()) {
        this.code += wild;
        this.renderWildcard(event);
      }
    } else {
      const composed = this.compositionChar(event);
      if (composed && this.canExtend(composed)) {
        this.code += composed;
        this.render(event);
      }
    }
    return true;
  }

  // Vertical menu of a symbol prefix's groups; picking one opens it.
  /** @param {KeyEvent} event */
  showGroupMenu(event) {
    this.groupMenu = true;
    const candidates = [];
    let indexLabels = "";
    for (const digit of SELECTION_KEYS) {
      const groupCode = this.code + digit;
      if (!symbolTable.has(groupCode)) continue;
      candidates.push({
        candidate: GROUP_NAMES[groupCode] ?? "符號組",
        payload: groupCode,
      });
      indexLabels += digit;
    }
    event.updateCandidates(candidates, {
      indexLabels,
      initialHighlight: -1,
      layoutDirection: "vertical",
    });
  }

  // Candidate-selection over a symbol group's symbols, annotated and vertical.
  /** @param {KeyEvent} event */
  enterSymbolGroup(event, symbols) {
    if (symbols.length === 0) {
      // Every symbol in this group is rare and hidden.
      this.reset();
      event.resetContext();
      return;
    }
    this.selecting = true;
    this.symbolGroup = true;
    this.groupMenu = false;
    event.updateMarkedText(symbols[0], { staged: -1 });
    event.updateCandidates(
      symbols.map((symbol) => ({
        candidate: symbol,
        annotation: symbolNames.get(symbol) ?? "",
      })),
      { initialHighlight: 0, layoutDirection: "vertical" }
    );
  }

  /** @param {KeyEvent} event */
  handleWildcardKey(event) {
    if (this.pageKey(event)) return true;
    if (this.isBareKey(event)) {
      switch (event.code) {
        case "Escape":
          this.reset();
          event.resetContext();
          return true;
        case "Backspace":
          this.code = this.code.slice(0, -1);
          if (!this.code) {
            this.reset();
            event.resetContext();
          } else if (hasWildcard(this.code)) {
            this.renderWildcard(event);
          } else {
            // No wildcard left — back to the normal preview.
            this.render(event);
          }
          return true;
        case "Space":
          event.navigateCandidates("pageForward", { wrapping: true });
          return true;
      }
    }
    // Composition key appends its position-derived char, wildcard key the typed
    // symbol — distinct sources, don't conflate to event.key.
    const key = this.compositionChar(event) ?? this.wildcardChar(event);
    if (key && this.canExtendWildcard()) {
      this.code += key;
      this.renderWildcard(event);
    }
    return true;
  }

  /** @param {KeyEvent} event */
  renderWildcard(event) {
    event.updateMarkedText(radicalReadout(this.code));
    // Vertical layout shows each candidate's code annotation more legibly.
    event.updateCandidates(wildcardMatches(this.code), {
      layoutDirection: "vertical",
    });
  }

  // Resolve candidates (main or phrase) and enter candidate-selection.
  /** @param {KeyEvent} event */
  enterSelecting(event, candidates) {
    this.groupMenu = false;
    if (candidates.length === 0) {
      // A code prefix with no character: nothing to select.
      this.reset();
      event.resetContext();
    } else if (candidates.length === 1) {
      // Commit via the host so a single char can enter associated mode.
      event.commit(candidates[0]);
    } else {
      this.selecting = true;
      this.symbolGroup = false;
      event.updateMarkedText(candidates[0], { staged: -1 });
      event.updateCandidates(candidates, { initialHighlight: 0 });
    }
  }

  /** @param {KeyEvent} event */
  handleSelectingKey(event) {
    if (this.pageKey(event)) return true;
    if (this.isBareKey(event)) {
      switch (event.code) {
        case "Escape":
          this.reset();
          event.resetContext();
          return true;
        case "Backspace":
          // Step back one stage: a symbol group returns to its menu, a
          // candidate list returns to the composing preview.
          if (this.symbolGroup) this.code = this.code.slice(0, -1);
          this.selecting = false;
          this.symbolGroup = false;
          if (this.code) {
            this.render(event);
          } else {
            this.reset();
            event.resetContext();
          }
          return true;
        case "Space":
          if (this.symbolGroup) {
            event.navigateCandidates("pageForward", { wrapping: true });
          } else {
            event.commitSelectedCandidate();
          }
          return true;
      }
    }
    const composed = this.compositionChar(event);
    if (composed) {
      // Flush the staged candidate, then start a fresh composition.
      event.flushStaged();
      this.reset();
      this.code = composed;
      this.render(event);
    }
    return true;
  }

  /** @param {ConfirmEvent} event */
  candidateConfirmed(event) {
    if (this.groupMenu) {
      // Group menu: open the picked group; no highlight yet is a no-op.
      if (event.payload) {
        this.code = event.payload;
        this.enterSymbolGroup(event, symbolTable.get(event.payload) ?? []);
      }
      return true;
    }
    // Enter with no highlight: in associated mode the host commits the held
    // char (fall through); otherwise it's a no-op.
    if (!event.candidate) return !event.isAssociating;
    // Outside associated mode, clear the staged preview so the host commits
    // exactly this candidate; in associated mode keep it for the follow-up.
    if (!event.isAssociating) event.updateMarkedText("");
    this.reset();
    // Host commits the candidate and may enter associated mode for a single char.
    return false;
  }

  /** @param {ConfirmEvent} event */
  candidateSelectionChanged(event) {
    // The markedText preview follows the highlight during candidate-selection.
    if (this.selecting) {
      event.updateMarkedText(event.candidate, { staged: -1 });
    }
    return true;
  }

  // Cap at MAX_CODE_LENGTH; the 5th key may only be the disambiguation key.
  canExtend(key) {
    if (this.code.length >= MAX_CODE_LENGTH) return false;
    if (this.code.length === MAX_CODE_LENGTH - 1 && key !== DISAMBIGUATION_KEY) {
      return false;
    }
    return true;
  }

  // Same length cap; the 5th-key rule doesn't apply to ? / *.
  canExtendWildcard() {
    return this.code.length < MAX_CODE_LENGTH;
  }

  // The Array key at `event`'s physical position; layout-independent.
  /** @param {KeyEvent} event */
  compositionChar(event) {
    if (!this.isBareKey(event)) return null;
    return arrayKeyForCode(event.code);
  }

  // The typed wildcard symbol ? / *. Char-based on purpose — a symbol, not a
  // position.
  /** @param {KeyEvent} event */
  wildcardChar(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return null;
    return event.key === "?" || event.key === "*" ? event.key : null;
  }

  /** @param {KeyEvent} event */
  render(event) {
    this.groupMenu = false;
    event.updateMarkedText(radicalReadout(this.code));
    if (this.code.length <= 2) {
      if (isSymbolPrefix(this.code)) {
        // A symbol prefix shows its group menu instead of short codes.
        this.showGroupMenu(event);
        return;
      }
      // Short codes; highlight the Space target's slot (-1 suspends if absent).
      const { candidates, indexLabels } = shortCodeView(this.code);
      const spaceTarget = (mainTable.get(this.code) ?? [])[0];
      event.updateCandidates(candidates, {
        indexLabels,
        initialHighlight: candidates.indexOf(spaceTarget),
      });
    } else {
      // Main candidates; an empty list (prefix en route) hides the window.
      event.updateCandidates(mainTable.get(this.code) ?? []);
    }
  }
}
