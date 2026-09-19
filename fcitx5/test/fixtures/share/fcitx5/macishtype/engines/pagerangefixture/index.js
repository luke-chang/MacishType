// KeyA opens 7 candidates over pages of 3, so the last page is short: its
// first slot holds a candidate and the other two are empty. KeyZ reports the
// snapshot's page range through the engine log. Every other key goes
// unhandled, so a digit the host did not intercept surfaces as a forward.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.updateCandidates(["c0", "c1", "c2", "c3", "c4", "c5", "c6"]);
      return true;
    }
    if (event.code === "KeyZ") {
      const cw = event.candidateWindow;
      console.log(
        `cw-range start=${cw.pageStart} end=${cw.pageEnd} visible=${cw.isVisible}`,
      );
      return true;
    }
    return false;
  }
}
