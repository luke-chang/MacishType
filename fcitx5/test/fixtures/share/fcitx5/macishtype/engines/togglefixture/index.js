// Exercises the capability-backed manifest.toggle surface end to end:
//   eval          - the key exists (and reads) from the first evaluated
//                   statement, before any session
//   self-write    - a JS write acts immediately and fires NO togglechange
//   togglechange  - a host-side flip (the chttrans hotkey) dispatches the
//                   event with the changed key
console.log(
  `togglefx eval value=${String(manifest.toggle.outputToSimplified)} ` +
    `keys=${JSON.stringify(Object.keys(manifest.toggle))}`,
);

addEventListener("togglechange", (event) => {
  console.log(
    `togglefx togglechange key=${event.key} ` +
      `value=${String(manifest.toggle.outputToSimplified)}`,
  );
});

export default class {
  handleKey(event) {
    if (event.key === "a") {
      manifest.toggle.outputToSimplified = true;
      console.log(
        `togglefx self-write value=${String(manifest.toggle.outputToSimplified)}`,
      );
      event.commit("w");
      return true;
    }
    if (event.key === "b") {
      console.log(
        `togglefx read value=${String(manifest.toggle.outputToSimplified)}`,
      );
      event.commit("r");
      return true;
    }
    return false;
  }
}
