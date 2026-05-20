// JS-port of Swift ExampleEngine — exercises the JavaScriptEngine bridge
// surface end-to-end (handleKey rules, candidate window, fullwidth, nav,
// associated mode).

// 1:1 port of Swift InputEngine.usKeyboardLayout (keyCodes 0-50 minus 10/36/48).
const usKeyboardLayout = {
  0: ["a", "A"],   1: ["s", "S"],  2: ["d", "D"],  3: ["f", "F"],
  4: ["h", "H"],   5: ["g", "G"],  6: ["z", "Z"],  7: ["x", "X"],
  8: ["c", "C"],   9: ["v", "V"],  11: ["b", "B"], 12: ["q", "Q"],
  13: ["w", "W"],  14: ["e", "E"], 15: ["r", "R"], 16: ["y", "Y"],
  17: ["t", "T"],  18: ["1", "!"], 19: ["2", "@"], 20: ["3", "#"],
  21: ["4", "$"],  22: ["6", "^"], 23: ["5", "%"], 24: ["=", "+"],
  25: ["9", "("],  26: ["7", "&"], 27: ["-", "_"], 28: ["8", "*"],
  29: ["0", ")"],  30: ["]", "}"], 31: ["o", "O"], 32: ["u", "U"],
  33: ["[", "{"],  34: ["i", "I"], 35: ["p", "P"], 37: ["l", "L"],
  38: ["j", "J"],  39: ["'", '"'], 40: ["k", "K"], 41: [";", ":"],
  42: ["\\", "|"], 43: [",", "<"], 44: ["/", "?"], 45: ["n", "N"],
  46: ["m", "M"],  47: [".", ">"], 49: [" ", " "], 50: ["`", "~"],
};

function toFullwidth(char) {
  if (char === " ") return "　";
  const code = char.charCodeAt(0);
  if (code < 0x21 || code > 0x7E) return null;
  return String.fromCharCode(code + 0xFEE0);
}

function navigationAction(keyCode, modifiers) {
  switch (keyCode) {
    case 48: return { direction: modifiers.shift ? "itemBackward" : "itemForward", wrapping: true };
    case 123: return { direction: "left" };
    case 124: return { direction: "right" };
    case 125: return { direction: "down" };
    case 126: return { direction: "up" };
    case 116: return { direction: "pageUp" };
    case 121: return { direction: "pageDown" };
    case 115: return { direction: "home" };
    case 119: return { direction: "end" };
    default: return null;
  }
}

const validCompositionCharacters = new Set("abcdefghijklmnopqrstuvwxyz");

// Module-scope demo table — kicks off at engine load. Hot-reload demo:
// editing demo.txt externally triggers a module reload and this fetch
// re-runs with the new content. Class methods read via closure.
// Format per line: `<key> <candidate1>,<candidate2>,...`
let demoTable = new Map();
fetch('./demo.txt')
  .then((r) => r.text())
  .then((text) => {
    const next = new Map();
    for (const line of text.split(/\r?\n/)) {
      const match = line.match(/^\s*(\S+)\s+(.+?)\s*$/);
      if (!match) continue;
      const [, key, valuesPart] = match;
      const values = valuesPart.split(',')
        .map((v) => v.trim())
        .filter((v) => v.length > 0);
      if (values.length > 0) next.set(key.toLowerCase(), values);
    }
    demoTable = next;
    console.info('demo.txt loaded, entries:', demoTable.size);
  })
  .catch((err) => {
    console.error('demo.txt load failed:', err.message);
  });

function lookupCandidates(key) {
  const values = demoTable.get(key.toLowerCase());
  if (values) {
    return values.map((text) => ({ candidate: text, annotation: 'demo' }));
  }
  return [...key].map(toFullwidth).filter((c) => c !== null);
}

function lookupAssociatedCandidates(char) {
  return [
    char.repeat(4),
    char.repeat(3),
    char.repeat(2),
    ...Array(20).fill(char),
  ];
}

// Bridge contract is duck-typed: engines export a default class with any
// of `activate / deactivate / handleKey / candidateConfirmed /
// candidateSelectionChanged`. Methods absent from the class are skipped.
// See ../Utils/MacishType.d.ts for the full type surface.

/** @typedef {import("../Utils/MacishType").InputEngine} InputEngine */
/** @typedef {import("../Utils/MacishType").KeyEvent} KeyEvent */
/** @typedef {import("../Utils/MacishType").ConfirmEvent} ConfirmEvent */

/** @implements {InputEngine} */
export default class JSExternalEngine {
  /** @param {KeyEvent} event */
  handleKey(event) {
    // Base rule 1: Cmd/Ctrl bypass — let modifier shortcuts pass through.
    if (event.modifiers.command || event.modifiers.ctrl) {
      if (event.isComposing) return true;
      return false;
    }

    // Base rule 2: indexLabels quick-commit while composing.
    if (event.isComposing && !event.modifiers.option
        && event.characters && event.characters.length === 1) {
      const idx = event.candidateWindow.candidateIndex(event.characters);
      if (idx !== null) {
        event.commitCandidateAtIndex(idx);
        return true;
      }
    }

    // Base rule 3: Uppercase letter passthrough.
    // Mirrors Swift `char.isUppercase && char.isLetter` — Unicode-aware.
    if (!event.modifiers.option && event.characters
        && event.characters.length === 1
        && event.characters.toUpperCase() === event.characters
        && event.characters.toLowerCase() !== event.characters) {
      if (event.isComposing) return true;
      event.flushStaged(event.characters);
      return true;
    }

    // Base rule 4: Esc.
    if (event.keyCode === 53) {
      if (!event.isComposing) return false;
      event.flushStaged();
      return true;
    }

    // Base rule 5: Navigation (arrows, Tab, Page, Home/End).
    const nav = navigationAction(event.keyCode, event.modifiers);
    if (nav) {
      if (!event.isComposing) return false;
      event.navigateCandidates(
        nav.direction,
        nav.wrapping ? { wrapping: true } : undefined
      );
      return true;
    }

    // Base rule 6: Enter.
    if (event.keyCode === 36) {
      if (!event.isComposing) return false;
      event.commitSelectedCandidate();
      return true;
    }

    // Base rule 7: Option+key fullwidth.
    if (event.modifiers.option) {
      const layout = usKeyboardLayout[event.keyCode];
      if (layout) {
        const ch = event.modifiers.shift ? layout[1] : layout[0];
        const fw = toFullwidth(ch);
        if (fw) {
          if (event.isComposing) return true;
          event.flushStaged(fw);
          return true;
        }
      }
    }

    // Engine-specific Space / Backspace / letter handling.
    const m = event.modifiers;
    if (m.command || m.ctrl || m.option || m.shift) return false;
    if (!event.characters || event.characters.length !== 1) {
      if (event.isComposing) return true;
      return false;
    }
    const char = event.characters;

    switch (event.keyCode) {
      case 49: { // Space → commit first candidate (engine-driven, runs candidateConfirmed pipeline)
        if (!event.isComposing) return false;
        const first = lookupCandidates(event.markedText)[0];
        if (first !== undefined) {
          event.commit(first);
        } else {
          event.resetContext();
        }
        return true;
      }
      case 51: { // Backspace
        if (!event.isComposing) return false;
        const newMarked = event.markedText.slice(0, -1);
        if (newMarked.length === 0) {
          event.resetContext();
          return true;
        }
        event.updateMarkedText(newMarked);
        event.updateCandidates(lookupCandidates(newMarked));
        return true;
      }
      default: {
        if (validCompositionCharacters.has(char)) {
          const newMarked = event.markedText + char.toUpperCase();
          event.updateMarkedText(newMarked);
          event.updateCandidates(lookupCandidates(newMarked));
          return true;
        }
        if (event.isComposing) return true;
        return false;
      }
    }
  }

  /** @param {ConfirmEvent} event */
  candidateConfirmed(event) {
    const { candidate } = event;
    if (event.isAssociating) {
      event.flushStaged(candidate);
      return;
    }
    if (manifest.settings.showAssociatedWords && candidate.length === 1) {
      const related = lookupAssociatedCandidates(candidate);
      if (related.length > 0) {
        event.enterAssociatedMode(candidate, related);
        return;
      }
    }
    event.flushStaged(candidate);
  }
}
