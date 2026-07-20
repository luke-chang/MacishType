// KeyA shows a multi-page candidate list with no initial highlight
// (suspended), so navigation-from-a-suspended-highlight can be tested:
// arrow keys should only reveal the first candidate, page keys should jump.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.updateCandidates(
        ["c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8"],
        { initialHighlight: -1, pageSize: 3 },
      );
      return true;
    }
    return false;
  }
}
