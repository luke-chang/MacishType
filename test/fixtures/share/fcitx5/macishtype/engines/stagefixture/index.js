// Drives the two focus-out cases: KeyA stages a character (committable on
// focus-out), KeyB leaves it composing (discarded on focus-out).
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.updateMarkedText("甲", { staged: -1 });
      return true;
    }
    if (event.code === "KeyB") {
      event.updateMarkedText("乙");
      return true;
    }
    return false;
  }
}
