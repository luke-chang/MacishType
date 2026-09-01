// Condition grammar coverage for manifest menu items. Every operator form
// decides one item's visibility; the host's resolved menu (the CLI `menu`
// verb) is the assertion surface, so this engine only reports the declared
// key set.
console.log(`condfx eval keys=${JSON.stringify(Object.keys(manifest.menu))}`);

export default class {
  handleKey() {
    return false;
  }
}
