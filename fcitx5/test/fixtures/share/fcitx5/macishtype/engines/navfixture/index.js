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
    if (event.code === "KeyB") {
      // Initial highlight on a later page (c5 is on page 2): the window must
      // open on the highlighted candidate's page, exercising setPage().
      event.updateCandidates(
        ["c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8"],
        { initialHighlight: 5, pageSize: 3 },
      );
      return true;
    }
    if (event.code === "KeyC") {
      // No window is up: commitSelectedCandidate must be a silent no-op
      // (window verbs require a visible window), not an empty commit.
      event.commitSelectedCandidate();
      return true;
    }
    return false;
  }
}
