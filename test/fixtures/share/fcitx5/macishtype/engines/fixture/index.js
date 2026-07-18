// Minimal contract-valid engine. Logs storage events so tests can assert
// the dispatch pipeline, and writes a key on activation so tests can
// assert both the storage location and that self-writes do not echo back
// as events.
addEventListener("storage", (event) => {
  console.log(`storage-event ${event.key}=${event.newValue}`);
});

export default class {
  activate() {
    localStorage.setItem("own", "self");
  }
}
