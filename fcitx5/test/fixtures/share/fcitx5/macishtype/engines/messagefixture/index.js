// Engine messages. KeyA shows one over a composition, KeyB replaces it with
// candidates, KeyC retires it and Escape ends the composition. Every other
// key is logged, so the test can see that keys still reach the engine while
// a message is up.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.updateMarkedText("a");
      event.updateMessage("No match");
      return true;
    }
    if (event.code === "KeyB") {
      event.updateCandidates(["甲"]);
      return true;
    }
    if (event.code === "KeyC") {
      event.updateMessage("");
      return true;
    }
    if (event.code === "Escape") {
      event.resetContext();
      return true;
    }
    console.log(
      `seen ${event.code} message=${event.message} ` +
        `visible=${event.candidateWindow.isVisible}`
    );
    return false;
  }
}
