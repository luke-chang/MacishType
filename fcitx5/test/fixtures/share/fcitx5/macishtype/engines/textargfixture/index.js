// Mutator text arguments that are not strings. KeyA composes so KeyB's
// undefined has something to clear and KeyH has a prefix to flush, KeyC puts
// a message up for KeyD to retire with null, KeyE holds an undefined text,
// KeyF puts a number on the message line, and KeyG hands the follow-up list
// an undefined element.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.updateMarkedText("a");
      return true;
    }
    if (event.code === "KeyB") {
      event.updateMarkedText(undefined);
      return true;
    }
    if (event.code === "KeyC") {
      event.updateMarkedText("c");
      event.updateMessage("No match");
      return true;
    }
    if (event.code === "KeyD") {
      event.updateMessage(null);
      return true;
    }
    if (event.code === "KeyE") {
      event.enterAssociatedMode(undefined, ["甲"]);
      return true;
    }
    if (event.code === "KeyF") {
      event.updateMarkedText("f");
      event.updateMessage(42);
      return true;
    }
    if (event.code === "KeyG") {
      event.enterAssociatedMode("x", [undefined, "甲"]);
      return true;
    }
    if (event.code === "KeyH") {
      event.updateMarkedText("x", { staged: -1 });
      event.flushStaged(42);
      return true;
    }
    return false;
  }
}
