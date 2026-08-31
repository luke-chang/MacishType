// Declares inherit, so the associated window keeps the engine's own labels
// and pageSize instead of digit selection; KeyA commits the character the
// scratch dictionary has follow-ups for.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.commit("中");
      return true;
    }
    return false;
  }
}
