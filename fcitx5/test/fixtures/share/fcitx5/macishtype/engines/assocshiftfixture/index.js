// Declares shiftNumbers, so the host's associated window selects with
// Shift + a physical digit key; KeyA commits the character the scratch
// dictionary has follow-ups for.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.commit("中");
      return true;
    }
    return false;
  }
}
