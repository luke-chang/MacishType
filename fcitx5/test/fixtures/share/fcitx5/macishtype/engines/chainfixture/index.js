// Chained associated input: each pick joins the staged prefix and re-enters
// associated mode with the next round's follow-ups, so nothing is committed
// until the chain runs dry.
const chain = { "存": ["錢", "款"], "錢": ["包", "幣"], "包": [] };

export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.enterAssociatedMode("存", chain["存"]);
      return true;
    }
    return false;
  }

  candidateConfirmed(event) {
    if (!event.isAssociating) return false;
    // Enter with no highlight arrives as an empty commit: let the host flush.
    if (!event.candidate) return false;
    event.enterAssociatedMode(event.stagedText + event.candidate,
                              chain[event.candidate] ?? []);
    return true;
  }
}
