// KeyA stages a prefix and offers a single-character candidate whose char
// has follow-ups in the scratch dictionary, so confirming it exercises the
// host's associated-mode fallback while a staged prefix is still pending.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.updateMarkedText("甲乙", { staged: 1 });
      event.updateCandidates(["中", "文"]);
      return true;
    }
    return false;
  }
}
