// Integer options that are not plain in-range integers. KeyA places the
// caret with NaN and KeyB with 2 ** 32; KeyC stages Infinity and flushes;
// KeyD emphasizes up to Infinity; KeyE and KeyF open a three-candidate
// window highlighting 2 ** 31 and -Infinity.
const LIST = ["甲", "乙", "丙"];

export default class {
  handleKey(event) {
    switch (event.code) {
      case "KeyA":
        event.updateMarkedText("xyz", { cursor: NaN });
        return true;
      case "KeyB":
        event.updateMarkedText("xyz", { cursor: 2 ** 32 });
        return true;
      case "KeyC":
        event.updateMarkedText("xyz", { staged: Infinity });
        event.flushStaged();
        return true;
      case "KeyD":
        event.updateMarkedText("xyz", { emphasis: { start: 0, end: Infinity } });
        return true;
      case "KeyE":
        event.updateMarkedText("e");
        event.updateCandidates(LIST, { initialHighlight: 2 ** 31 });
        return true;
      case "KeyF":
        event.updateMarkedText("f");
        event.updateCandidates(LIST, { initialHighlight: -Infinity });
        return true;
    }
    return false;
  }
}
