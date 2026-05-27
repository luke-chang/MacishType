// JS-port of Swift ExampleEngine — exercises the JavaScriptEngine bridge
// surface end-to-end (handleKey rules, candidate window, fullwidth, nav,
// associated mode).

// Maps web `event.code` (layout-independent US QWERTY physical position) to
// [unshifted, shifted] US character pair. Mirrors the Swift InputEngine's
// fullwidth lookup but keyed by code string so it works across layouts —
// AZERTY's physical "A" position still goes to fullwidth "ａ" even though
// the user types "q" there.
const usKeyForCode = {
  KeyA: ["a", "A"], KeyB: ["b", "B"], KeyC: ["c", "C"], KeyD: ["d", "D"],
  KeyE: ["e", "E"], KeyF: ["f", "F"], KeyG: ["g", "G"], KeyH: ["h", "H"],
  KeyI: ["i", "I"], KeyJ: ["j", "J"], KeyK: ["k", "K"], KeyL: ["l", "L"],
  KeyM: ["m", "M"], KeyN: ["n", "N"], KeyO: ["o", "O"], KeyP: ["p", "P"],
  KeyQ: ["q", "Q"], KeyR: ["r", "R"], KeyS: ["s", "S"], KeyT: ["t", "T"],
  KeyU: ["u", "U"], KeyV: ["v", "V"], KeyW: ["w", "W"], KeyX: ["x", "X"],
  KeyY: ["y", "Y"], KeyZ: ["z", "Z"],
  Digit1: ["1", "!"], Digit2: ["2", "@"], Digit3: ["3", "#"],
  Digit4: ["4", "$"], Digit5: ["5", "%"], Digit6: ["6", "^"],
  Digit7: ["7", "&"], Digit8: ["8", "*"], Digit9: ["9", "("],
  Digit0: ["0", ")"],
  Minus: ["-", "_"], Equal: ["=", "+"],
  BracketLeft: ["[", "{"], BracketRight: ["]", "}"],
  Backslash: ["\\", "|"], Semicolon: [";", ":"], Quote: ["'", '"'],
  Comma: [",", "<"], Period: [".", ">"], Slash: ["/", "?"],
  Backquote: ["`", "~"], Space: [" ", " "],
};

function toFullwidth(char) {
  if (char === " ") return "　";
  const code = char.charCodeAt(0);
  if (code < 0x21 || code > 0x7E) return null;
  return String.fromCharCode(code + 0xFEE0);
}

function navigationAction(event) {
  switch (event.code) {
    case "Tab": return { direction: event.shiftKey ? "itemBackward" : "itemForward", wrapping: true };
    case "ArrowLeft": return { direction: "left" };
    case "ArrowRight": return { direction: "right" };
    case "ArrowDown": return { direction: "down" };
    case "ArrowUp": return { direction: "up" };
    case "PageUp": return { direction: "pageUp" };
    case "PageDown": return { direction: "pageDown" };
    case "Home": return { direction: "home" };
    case "End": return { direction: "end" };
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
    if (event.metaKey || event.ctrlKey) {
      if (event.isComposing) return true;
      return false;
    }

    // Base rule 2: indexLabels quick-commit while composing. `event.key`
    // returns named-key strings (e.g. "Backspace") for non-character keys,
    // so the `length === 1` guard is required before treating it as a
    // candidate label character.
    if (event.isComposing && !event.altKey
        && event.key && event.key.length === 1) {
      const idx = event.candidateWindow.candidateIndex(event.key);
      if (idx !== null) {
        event.commitCandidateAtIndex(idx);
        return true;
      }
    }

    // Base rule 3: Uppercase letter passthrough. Single-char guard, see rule 2.
    if (!event.altKey && event.key
        && event.key.length === 1
        && event.key.toUpperCase() === event.key
        && event.key.toLowerCase() !== event.key) {
      if (event.isComposing) return true;
      event.flushStaged(event.key);
      return true;
    }

    // Base rule 4: Esc.
    if (event.code === "Escape") {
      if (!event.isComposing) return false;
      event.flushStaged();
      return true;
    }

    // Base rule 5: Navigation (arrows, Tab, Page, Home/End).
    const nav = navigationAction(event);
    if (nav) {
      if (!event.isComposing) return false;
      event.navigateCandidates(
        nav.direction,
        nav.wrapping ? { wrapping: true } : undefined
      );
      return true;
    }

    // Base rule 6: Enter.
    if (event.code === "Enter") {
      if (!event.isComposing) return false;
      event.commitSelectedCandidate();
      return true;
    }

    // Base rule 7: Option+key fullwidth. Look up the US-layout character by
    // physical `code` so the mapping stays stable across input sources —
    // Option+physical-A always yields fullwidth "ａ" even on AZERTY/Dvorak.
    if (event.altKey) {
      const layout = usKeyForCode[event.code];
      if (layout) {
        const ch = event.shiftKey ? layout[1] : layout[0];
        const fw = toFullwidth(ch);
        if (fw) {
          if (event.isComposing) return true;
          event.flushStaged(fw);
          return true;
        }
      }
    }

    // Engine-specific Space / Backspace / letter handling.
    if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return false;

    // Named-key actions must run before the character path below: otherwise
    // Space (`event.key === " "` passes length guard but isn't in
    // validCompositionCharacters) and Backspace (length-9 name fails guard)
    // would both hit the composing-default-true trap and silently no-op.
    if (event.code === "Space") {
      // commit first candidate (engine-driven, runs candidateConfirmed pipeline)
      if (!event.isComposing) return false;
      const first = lookupCandidates(event.markedText)[0];
      if (first !== undefined) {
        event.commit(first);
      } else {
        event.resetContext();
      }
      return true;
    }
    if (event.code === "Backspace") {
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

    // Character composition path — letter keys produce a single-char key.
    if (!event.key || event.key.length !== 1) {
      if (event.isComposing) return true;
      return false;
    }
    const char = event.key;
    if (validCompositionCharacters.has(char)) {
      const newMarked = event.markedText + char.toUpperCase();
      event.updateMarkedText(newMarked);
      event.updateCandidates(lookupCandidates(newMarked));
      return true;
    }
    if (event.isComposing) return true;
    return false;
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
