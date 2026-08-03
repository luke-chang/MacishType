// capability outputToSimplified: false removes the manifest.toggle key even
// for a Traditional-Chinese engine; writes to the unavailable key are
// ignored with a warning. The malformed fullwidthInput ("yes") must be
// warned about and treated as undeclared (no fullwidth module pulled in).
console.log(
  `toggleofffx eval value=${String(manifest.toggle.outputToSimplified)} ` +
    `keys=${JSON.stringify(Object.keys(manifest.toggle))}`,
);

export default class {
  handleKey(event) {
    if (event.key === "a") {
      manifest.toggle.outputToSimplified = true;
      console.log(
        `toggleofffx write-after value=${String(manifest.toggle.outputToSimplified)}`,
      );
      event.commit("x");
      return true;
    }
    return false;
  }
}
