// Candidate mutator arguments off their declared types. KeyA lists items
// that are not strings, KeyB commits a number, KeyC shows two candidates for
// KeyD to aim commitCandidateAtIndex at with non-numbers and KeyE with 1.
// KeyF through KeyI each send one per-update window option outside the
// manifest's ranges, which must leave the manifest's vertical, three-per-page
// "abc" window in place; KeyJ sends valid ones.
const SIX = ["一", "二", "三", "四", "五", "六"];

export default class {
  handleKey(event) {
    switch (event.code) {
      case "KeyA":
        event.updateMarkedText("a");
        event.updateCandidates([42, null, { candidate: 7, annotation: 8 }]);
        return true;
      case "KeyB":
        event.updateMarkedText("b");
        event.commit(42);
        return true;
      case "KeyC":
        event.updateMarkedText("c");
        event.updateCandidates(["甲", "乙"]);
        return true;
      case "KeyD":
        event.commitCandidateAtIndex(undefined);
        event.commitCandidateAtIndex(null);
        event.commitCandidateAtIndex("1");
        event.commitCandidateAtIndex(NaN);
        return true;
      case "KeyE":
        event.commitCandidateAtIndex(1);
        return true;
      case "KeyF":
        event.updateMarkedText("f");
        event.updateCandidates(SIX, { pageSize: 20 });
        return true;
      case "KeyG":
        event.updateMarkedText("g");
        event.updateCandidates(SIX, { pageSize: 2.5 });
        return true;
      case "KeyH":
        event.updateMarkedText("h");
        event.updateCandidates(SIX, { layoutDirection: "diagonal" });
        return true;
      case "KeyI":
        event.updateMarkedText("i");
        event.updateCandidates(SIX, { indexLabels: "あいう" });
        return true;
      case "KeyJ":
        event.updateMarkedText("j");
        event.updateCandidates(SIX, {
          pageSize: 2,
          layoutDirection: "horizontal",
          indexLabels: "xyz",
        });
        return true;
    }
    return false;
  }
}
