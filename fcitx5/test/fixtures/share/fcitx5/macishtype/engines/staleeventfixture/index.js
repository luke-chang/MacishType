// KeyA keeps its event. KeyZ commits through that kept event and then its
// own, and each lifecycle hook commits through the kept event. Only KeyZ's
// own commit belongs to a running call.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      this.kept = event;
      return true;
    }
    if (event.code === "KeyZ") {
      this.kept?.commit("stale-key");
      event.commit("fresh");
      return true;
    }
    return false;
  }

  activate() {
    this.kept?.commit("stale-activate");
  }

  deactivate() {
    this.kept?.commit("stale-deactivate");
  }

  compositionEnded() {
    this.kept?.commit("stale-compositionEnded");
  }
}
