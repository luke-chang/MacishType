// The host drops each broken menu item with a notice; the surviving toggle
// keeps the first declaration's default.
console.log(
  `menubadfx eval keys=${JSON.stringify(Object.keys(manifest.menu))} ` +
    `good=${String(manifest.menu.good)}`,
);

export default class {
  handleKey() {
    return false;
  }
}
