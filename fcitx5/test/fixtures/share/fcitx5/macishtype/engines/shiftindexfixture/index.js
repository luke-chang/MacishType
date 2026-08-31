// The Shift requirement as a first-class engine field on an ordinary
// candidate window, with mixed labels so non-digit ones stay plain. KeyQ
// replays candidateIndex against synthetic events to pin the matching rules.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.updateCandidates(["c0", "c1", "c2", "c3"]);
      return true;
    }
    if (event.code === "KeyQ") {
      const cw = event.candidateWindow;
      console.log(`ci-flag ${String(cw.indexLabelDigitsRequireShift)}`);
      console.log(
        `ci-event-shift ${cw.candidateIndex({ key: "!", code: "Digit1", shiftKey: true })}`,
      );
      console.log(
        `ci-event-noshift ${cw.candidateIndex({ key: "1", code: "Digit1", shiftKey: false })}`,
      );
      console.log(`ci-string-digit ${cw.candidateIndex("1")}`);
      console.log(
        `ci-unknown-code ${cw.candidateIndex({ key: "a", code: "", shiftKey: false })}`,
      );
      console.log(
        `ci-alt ${cw.candidateIndex({ key: "a", code: "KeyA", altKey: true })}`,
      );
      return true;
    }
    return false;
  }
}
