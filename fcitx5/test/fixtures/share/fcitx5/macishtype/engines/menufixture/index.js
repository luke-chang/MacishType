// Exercises the manifest.menu surface end to end:
//   eval        - declared keys exist with their defaults from the first
//                 evaluated statement, in declaration order
//   self-write  - a JS write acts immediately and fires NO menuchange
//   menuchange  - a host-side flip dispatches the event with no key; the
//                 new values are read back from manifest.menu
console.log(
  `menufx eval keys=${JSON.stringify(Object.keys(manifest.menu))} ` +
    `strict=${String(manifest.menu.strictMode)} ` +
    `verbose=${String(manifest.menu.verboseHints)} ` +
    `extra=${String(manifest.menu.extraPanel)} ` +
    `undeclared=${String(manifest.menu.notDeclared)}`,
);

addEventListener("menuchange", (event) => {
  console.log(
    `menufx menuchange key=${String(event.key)} ` +
      `strict=${String(manifest.menu.strictMode)} ` +
      `verbose=${String(manifest.menu.verboseHints)} ` +
      `extra=${String(manifest.menu.extraPanel)}`,
  );
});

export default class {
  handleKey(event) {
    if (event.key === "a") {
      manifest.menu.strictMode = !manifest.menu.strictMode;
      console.log(
        `menufx self-write strict=${String(manifest.menu.strictMode)}`,
      );
      event.commit("w");
      return true;
    }
    if (event.key === "b") {
      manifest.menu.notDeclared = true;
      manifest.menu.strictMode = "yes";
      console.log(
        `menufx bad-writes strict=${String(manifest.menu.strictMode)}`,
      );
      event.commit("x");
      return true;
    }
    if (event.key === "c") {
      console.log(`menufx read strict=${String(manifest.menu.strictMode)}`);
      event.commit("r");
      return true;
    }
    return false;
  }
}
