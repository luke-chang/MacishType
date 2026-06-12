// Tests for the Array (行列) JS engine, run with Node's built-in test runner:
//
//   node --test Engines/ArrayEngine/index.test.mjs
//
// (Point it at this file, not the folder — folder mode would try to run the
// engine module index.js as a test and crash on the missing host globals.)
//
// No npm dependencies. The engine expects host-injected globals (fetch,
// manifest, addEventListener, console); we stub them, back fetch with the real
// data files in this folder, then drive the engine with synthetic key events
// whose mutator calls are recorded for assertions.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

globalThis.manifest = { settings: { showRareCharacters: false } };
globalThis.addEventListener = () => {};
// Silence the engine's load-progress logs; keep errors visible.
globalThis.console = { ...console, info: () => {}, debug: () => {} };
globalThis.fetch = async (path) => ({
  text: () => readFile(new URL(path, import.meta.url), "utf8"),
});

const { default: ArrayEngine } = await import("./index.js");

// A synthetic KeyEvent / ConfirmEvent: read-only fields plus mutators that
// record their calls. `last(name)` returns the most recent call by that name.
function makeEvent(props = {}) {
  const calls = [];
  const record = (name) => (...args) => calls.push({ name, args });
  return {
    isComposing: false,
    metaKey: false, ctrlKey: false, altKey: false, shiftKey: false,
    key: "", code: "", keyIgnoringModifiers: "",
    candidate: "", payload: undefined, isAssociating: false,
    candidateWindow: { isVisible: false },
    updateMarkedText: record("updateMarkedText"),
    updateCandidates: record("updateCandidates"),
    commit: record("commit"),
    commitSelectedCandidate: record("commitSelectedCandidate"),
    navigateCandidates: record("navigateCandidates"),
    resetContext: record("resetContext"),
    flushStaged: record("flushStaged"),
    calls,
    last(name) {
      for (let i = calls.length - 1; i >= 0; i--) {
        if (calls[i].name === name) return calls[i];
      }
      return undefined;
    },
    ...props,
  };
}

// Composition is read by position (event.code), so synthetic events need the
// W3C code; wildcards (?/*) stay key-based.
const KEY_TO_CODE = { ",": "Comma", ".": "Period", "/": "Slash", ";": "Semicolon" };
function codeForKey(key) {
  if (KEY_TO_CODE[key]) return KEY_TO_CODE[key];
  return /^[a-z]$/.test(key) ? "Key" + key.toUpperCase() : "";
}

// Type composition keys; the first lands while idle, the rest while composing.
function compose(engine, keys) {
  let event;
  keys.forEach((key, index) => {
    event = makeEvent({ key, code: codeForKey(key), isComposing: index > 0 });
    engine.handleKey(event);
  });
  return event;
}

// Data loads via fetch().then() are async; wait until the main table is
// populated by probing a code that resolves to a single character.
async function settle() {
  for (let attempt = 0; attempt < 200; attempt++) {
    const engine = new ArrayEngine();
    engine.activate();
    compose(engine, ["t"]);
    const space = makeEvent({ isComposing: true, code: "Space" });
    engine.handleKey(space);
    if (space.last("commit")) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error("data tables did not load");
}
await settle();

function freshEngine() {
  const engine = new ArrayEngine();
  engine.activate();
  return engine;
}

test("composing a key shows its radical readout and a candidate list", () => {
  const engine = freshEngine();
  const event = compose(engine, ["t"]);
  assert.equal(engine.code, "t");
  assert.equal(event.last("updateMarkedText").args[0], "5⇡");
  assert.ok(Array.isArray(event.last("updateCandidates").args[0]));
});

test("composition follows physical position, not the layout's character", () => {
  // Mismatched layout: physical "A" (code "KeyA") yields key "q"; the radical
  // must follow the position (→ 1-), not the character.
  const engine = freshEngine();
  const event = makeEvent({ key: "q", code: "KeyA" });
  engine.handleKey(event);
  assert.equal(engine.code, "a");
  assert.equal(event.last("updateMarkedText").args[0], "1-");
});

test("Space on a single-candidate code commits it", () => {
  const engine = freshEngine();
  compose(engine, ["t"]);
  const space = makeEvent({ isComposing: true, code: "Space" });
  engine.handleKey(space);
  assert.equal(space.last("commit").args[0], "的");
});

test("Backspace removes one key, then clears the composition", () => {
  const engine = freshEngine();
  compose(engine, ["a", "b"]);
  assert.equal(engine.code, "ab");

  const back1 = makeEvent({ isComposing: true, code: "Backspace" });
  engine.handleKey(back1);
  assert.equal(engine.code, "a");

  const back2 = makeEvent({ isComposing: true, code: "Backspace" });
  engine.handleKey(back2);
  assert.equal(engine.code, "");
  assert.ok(back2.last("resetContext"));
});

test("Escape clears the composition", () => {
  const engine = freshEngine();
  compose(engine, ["t"]);
  const escape = makeEvent({ isComposing: true, code: "Escape" });
  engine.handleKey(escape);
  assert.equal(engine.code, "");
  assert.ok(escape.last("resetContext"));
});

test("a modified control key is inert while composing (bare-key gate)", () => {
  const engine = freshEngine();
  compose(engine, ["t"]);
  const shiftBack = makeEvent({
    isComposing: true, code: "Backspace", shiftKey: true,
  });
  const handled = engine.handleKey(shiftBack);
  assert.equal(handled, true); // eaten, not passed to the OS
  assert.equal(engine.code, "t"); // but no backspace happened
  assert.equal(shiftBack.last("resetContext"), undefined);
});

test("Option + printable commits the full-width form when idle", () => {
  const engine = freshEngine();
  const event = makeEvent({ key: "!", keyIgnoringModifiers: "!", altKey: true });
  engine.handleKey(event);
  assert.equal(event.last("flushStaged").args[0], "！");
});

test("a symbol prefix shows a vertical group menu", () => {
  const engine = freshEngine();
  const event = compose(engine, ["w"]);
  const update = event.last("updateCandidates");
  assert.equal(update.args[1].layoutDirection, "vertical");
  assert.equal(update.args[1].initialHighlight, -1);
  // Groups are listed in selection-key order (1..9, 0), so w1 leads and w0 is last.
  assert.ok(update.args[0].some((candidate) => candidate.payload === "w0"));
});

test("confirming a group opens its symbols", () => {
  const engine = freshEngine();
  compose(engine, ["w"]);
  const confirm = makeEvent({ payload: "w0", candidate: "注音符號組" });
  engine.candidateConfirmed(confirm);
  assert.equal(engine.symbolGroup, true);
  assert.equal(confirm.last("updateCandidates").args[0][0].candidate, "ㄅ");
  assert.equal(confirm.last("updateMarkedText").args[0], "ㄅ");
});

test("Backspace in a symbol group steps back to the group menu", () => {
  const engine = freshEngine();
  compose(engine, ["w"]);
  engine.candidateConfirmed(makeEvent({ payload: "w0", candidate: "注音符號組" }));

  const back = makeEvent({ isComposing: true, code: "Backspace" });
  engine.handleKey(back);
  assert.equal(engine.code, "w");
  assert.equal(engine.selecting, false);
  assert.ok(back.last("updateCandidates").args[0].some((c) => c.payload === "w0"));
});

test("leading * matches by containment, not an exact key set", () => {
  const engine = freshEngine();
  const event = compose(engine, ["*", "t"]);
  const candidates = event.last("updateCandidates").args[0];
  // Containment matches every code containing "t" (hundreds, capped); an
  // exact-set match would yield only the few codes that are exactly "t".
  assert.ok(candidates.length > 50, `got ${candidates.length}`);
  assert.ok(candidates.length <= 200);
});

test("positional wildcard matches by pattern", () => {
  const engine = freshEngine();
  const event = compose(engine, ["?", "?"]);
  assert.ok(event.last("updateCandidates").args[0].length > 0);
});

test("paging keys navigate only with the right modifiers", () => {
  const engine = freshEngine();
  compose(engine, ["t"]);
  const visible = { candidateWindow: { isVisible: true }, isComposing: true };

  const equal = makeEvent({ ...visible, code: "Equal" });
  engine.handleKey(equal);
  assert.equal(equal.last("navigateCandidates").args[0], "pageForward");

  const shiftRight = makeEvent({ ...visible, code: "ArrowRight", shiftKey: true });
  engine.handleKey(shiftRight);
  assert.equal(shiftRight.last("navigateCandidates").args[0], "pageForward");

  // Shift+= is "+", not a page.
  const shiftEqual = makeEvent({ ...visible, code: "Equal", shiftKey: true });
  engine.handleKey(shiftEqual);
  assert.equal(shiftEqual.last("navigateCandidates"), undefined);
});
