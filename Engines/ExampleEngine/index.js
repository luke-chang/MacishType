// JS-port of Swift ExampleEngine — exercises the JavaScriptEngine bridge
// surface end-to-end (handleKey rules, candidate window, the fullwidthInput
// capability, associated mode). Standard nav keys, Enter, and indexLabels
// keys are handled by the host while the candidate window is visible.

const validCompositionCharacters = new Set("abcdefghijklmnopqrstuvwxyz");

// Escape or keypad Clear. Clear's web code is "NumLock" (W3C position
// semantics), so match it by key.
function isEscapeKey(event) {
  return event.code === "Escape" || event.key === "Clear";
}

// A-Z → common zh-Hant characters, for exercising the system-provided
// associated mode.
const keyMap = {
  A: '的', B: '是', C: '一', D: '不', E: '有',
  F: '在', G: '我', H: '人', I: '這', J: '了',
  K: '個', L: '以', M: '會', N: '大', O: '為',
  P: '來', Q: '要', R: '中', S: '國', T: '他',
  U: '到', V: '就', W: '們', X: '上', Y: '可',
  Z: '也',
};

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
  return [...key].map((c) => keyMap[c.toUpperCase()]).filter((c) => c !== undefined);
}

function applyComposition(event, marked) {
  event.updateMarkedText(marked);
  event.updateCandidates(lookupCandidates(marked));
}

// Bridge contract is duck-typed: engines export a default class with any
// of `activate / deactivate / handleKey / candidateConfirmed /
// candidateSelectionChanged`. Methods absent from the class are skipped.
// See ../Utils/MacishType.d.ts for the full type surface.

/** @typedef {import("../Utils/MacishType").InputEngine} InputEngine */
/** @typedef {import("../Utils/MacishType").KeyEvent} KeyEvent */

/** @implements {InputEngine} */
export default class JSExternalEngine {
  /** @param {KeyEvent} event */
  handleKey(event) {
    // Numeric-keypad rule: keypad character keys never compose — swallow
    // while composing, pass through when idle. Modifier combos and
    // NumpadEnter stay on their normal paths (Clear's code is "NumLock").
    if (event.code.startsWith("Numpad") && event.code !== "NumpadEnter"
        && !event.metaKey && !event.ctrlKey && !event.altKey) {
      return event.isComposing;
    }

    if (event.isComposing) {
      if (isEscapeKey(event)) {
        event.flushStaged();
      } else if (event.code === "Space") {
        const first = lookupCandidates(event.markedText)[0];
        first ? event.commit(first) : event.resetContext();
      } else if (event.code === "Backspace") {
        const newMarked = event.markedText.slice(0, -1);
        newMarked ? applyComposition(event, newMarked) : event.resetContext();
      } else if (!event.metaKey && !event.ctrlKey && !event.altKey
                 && event.key.length === 1
                 && validCompositionCharacters.has(event.key)) {
        applyComposition(event, event.markedText + event.key.toUpperCase());
      }
      // Anything not explicitly handled is eaten so composing stays intact.
      return true;
    }

    if (event.metaKey || event.ctrlKey) return false;

    // Exclude altKey so a modified letter declines instead of starting
    // composition.
    if (!event.altKey
        && event.key.length === 1
        && validCompositionCharacters.has(event.key)) {
      applyComposition(event, event.key.toUpperCase());
      return true;
    }
    return false;
  }
}
