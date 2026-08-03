// Minimal contract-valid engine. Logs storage events and settings state
// so tests can assert the dispatch pipelines, and writes a storage key on
// activation so tests can assert both the storage location and that
// self-writes do not echo back as events.
addEventListener("storage", (event) => {
  console.log(`storage-event ${event.key}=${event.newValue}`);
});

console.log(`settings ${JSON.stringify(manifest.settings)}`);
addEventListener("settingschange", () => {
  console.log(`settings-changed ${JSON.stringify(manifest.settings)}`);
});

export default class {
  activate() {
    localStorage.setItem("own", "self");
  }
}
