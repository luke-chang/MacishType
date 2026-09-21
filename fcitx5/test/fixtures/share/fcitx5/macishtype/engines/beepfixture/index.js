// KeyA beeps once. KeyZ beeps three times inside one hook, which the host
// collapses into a single sound. Every other key goes unhandled.
export default class {
  handleKey(event) {
    if (event.code === "KeyA") {
      event.beep();
      return true;
    }
    if (event.code === "KeyZ") {
      event.beep();
      event.beep();
      event.beep();
      return true;
    }
    return false;
  }
}
