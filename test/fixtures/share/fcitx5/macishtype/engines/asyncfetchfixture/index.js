// Exercises the deferred-fetch pipeline: the module finishes evaluating (and
// the engine is usable) before the table's read+parse runs, so the host's
// "Engine loaded" line must precede the parsed marker below — the ordering
// flips exactly when fetch stops resolving synchronously during load.
console.log("asyncfetch eval-done");

// text() must reject invalid UTF-8 even after an embedded NUL.
fetch("./invalid.bin")
  .then((response) => response.text())
  .then(() => console.log("asyncfetch nul-text no-throw"))
  .catch((error) => console.log(`asyncfetch nul-text ${error.constructor.name} msg=${error.message}`));

let table = null;
fetch("./table.json")
  .then((response) => response.json())
  .then((data) => {
    table = data;
    console.log(`asyncfetch parsed entries=${Object.keys(data).length}`);
  })
  .catch((error) => console.log(`asyncfetch failed ${error.message}`));

export default class {
  handleKey(event) {
    if (event.key === "a") {
      event.commit(table ? "loaded" : "basic");
      return true;
    }
    return false;
  }
}
