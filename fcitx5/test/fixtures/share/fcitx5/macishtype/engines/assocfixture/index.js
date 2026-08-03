// KeyA commits a single character, which the host follows with associated
// mode when the scratch dictionary has entries for it. Other keys pass
// through so a keystroke can dismiss associated mode.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.commit("中");
      return true;
    }
    return false;
  }
}
