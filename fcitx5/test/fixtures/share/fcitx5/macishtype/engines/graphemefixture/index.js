// Multi-code-point grapheme clusters at the character-index surfaces. KeyA
// emits marked text whose clusters are a variation sequence (U+2699 U+FE0E),
// a combining mark (e U+0301), an emoji ZWJ sequence, and "x", with
// mid-string staged/cursor/emphasis indices. KeyB enters associated mode
// with held text ending in the variation sequence, keying the host
// dictionary off that full trailing cluster.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.updateMarkedText("⚙︎é\u{1F469}‍\u{1F4BB}x", {
        staged: 1,
        cursor: 2,
        emphasis: { start: 1, end: 3 },
      });
      return true;
    }
    if (event.code === "KeyB") {
      event.enterAssociatedMode("存⚙︎");
      return true;
    }
    return false;
  }
}
