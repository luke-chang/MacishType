// Opts out of host index-label handling while requiring Shift on digits, so
// the keys must reach handleKey. Commits "ci<index>" — a host that selected
// the candidate itself would commit "c<index>" instead.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.updateCandidates(["c0", "c1", "c2", "c3"]);
      return true;
    }
    if (!event.candidateWindow.isVisible) return false;
    const index = event.candidateWindow.candidateIndex(event);
    if (index !== null) {
      event.commit(`ci${index}`);
      return true;
    }
    return false;
  }
}
