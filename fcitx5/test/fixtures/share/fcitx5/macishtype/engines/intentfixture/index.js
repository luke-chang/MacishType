// Opts out of handleNavigationKeys / handleIndexLabelKeys and replays the
// candidateWindow helpers itself, so navigationIntent() and candidateIndex()
// results are observable: intents feed navigateCandidates, a matched index
// label commits "ci<index>", everything else passes through unhandled.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.updateCandidates(
        ["c0", "c1", "c2", "c3", "c4", "c5", "c6"],
        { initialHighlight: 0, pageSize: 3 },
      );
      return true;
    }
    if (!event.candidateWindow.isVisible) return false;
    const intent = event.candidateWindow.navigationIntent(event);
    if (intent) {
      event.navigateCandidates(intent.direction, intent.options);
      return true;
    }
    const index = event.candidateWindow.candidateIndex(event.key);
    if (index !== null) {
      event.commit(`ci${index}`);
      return true;
    }
    return false;
  }
}
