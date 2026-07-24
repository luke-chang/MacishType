// Hosts the reverseLookup capability. The class exposes the three static
// methods the Find Input Code surface drives: prepareReverseLookup builds an
// index from a fetched table (the deferred, non-blocking path), reverseLookup
// answers one character, and endReverseLookup releases the index. The console
// markers let the host test assert each call and its ordering; the index is
// built once, so a re-triggered lookup logs "cached" instead of rebuilding.
export default class {
  // A normal key composes, proving typing resumes after the read-only reverse
  // display is dismissed by that same keystroke.
  handleKey(event) {
    if (event.key === "a") {
      event.commit("Z");
      return true;
    }
    return false;
  }

  static async prepareReverseLookup() {
    console.log("revfix prepare:enter");
    if (this.index) {
      console.log("revfix prepare:cached");
      return;
    }
    const response = await fetch("./table.json");
    this.index = await response.json();
    console.log(`revfix prepare:built entries=${Object.keys(this.index).length}`);
  }

  static reverseLookup(character) {
    console.log(`revfix lookup:${character}`);
    return (this.index && this.index[character]) || [];
  }

  static endReverseLookup() {
    console.log("revfix end");
    this.index = null;
  }
}
