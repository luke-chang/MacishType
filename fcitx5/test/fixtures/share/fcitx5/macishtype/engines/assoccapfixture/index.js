// Supplies eleven follow-ups of its own so the digit branch's pageSize cap
// is observable: the first page must show ten and report another page.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.enterAssociatedMode("甲", [
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11",
      ]);
      return true;
    }
    return false;
  }
}
