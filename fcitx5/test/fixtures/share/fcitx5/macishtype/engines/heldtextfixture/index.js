// enterAssociatedMode with no held text. KeyA supplies follow-ups anyway,
// KeyB supplies none. Every other key is logged, so the test can see that
// the session is not left associating.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.enterAssociatedMode("", ["甲", "乙"]);
      return true;
    }
    if (event.code === "KeyB") {
      event.enterAssociatedMode("");
      return true;
    }
    console.log(
      `seen ${event.code} associating=${event.isAssociating} ` +
        `visible=${event.candidateWindow.isVisible}`
    );
    return false;
  }
}
