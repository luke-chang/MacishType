// Shows candidates on KeyA. The manifest declares no candidateWindow
// layoutDirection, so the addon auto-generates the orientation setting; the
// candidate window's layout hint reflects the resolved direction.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.updateCandidates(["甲", "乙"]);
      return true;
    }
    return false;
  }
}
