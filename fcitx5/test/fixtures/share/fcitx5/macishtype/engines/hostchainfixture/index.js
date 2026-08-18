// Chained associated input sourced entirely from the host dictionary: each
// pick joins the staged prefix and re-enters associated mode without
// supplying candidates, so the host keys the next round off the last char.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.enterAssociatedMode("存");
      return true;
    }
    return false;
  }

  candidateConfirmed(event) {
    if (!event.isAssociating) return false;
    // Enter with no highlight arrives as an empty commit: let the host flush.
    if (!event.candidate) return false;
    event.enterAssociatedMode(event.stagedText + event.candidate);
    return true;
  }
}
