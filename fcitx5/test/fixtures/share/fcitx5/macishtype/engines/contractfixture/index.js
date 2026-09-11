// Load-time conformance checks for several small contract fixes, each logging
// a marker the test asserts on. Run under a controlled LANGUAGE so the locale
// checks are deterministic. Markers map to:
//   nav-languages    - navigator.languages carries the region->base chain
//   manifest-name     - a name locale-map with no match falls back to the
//                       lowest-sorted key, not the first-declared one
//   root-import       - a "/util.js" import resolves from the engine root
//   key-order         - localStorage.key(index) reports keys alphabetically
//   cw-impl           - per-implementation candidateWindow fields, and the
//                       macish section itself, are unreadable, unwritable,
//                       unlisted; top-level fields still seed the proxy
//   indexlabels-*     - a non-ASCII indexLabels write is rejected
//   pagesize-*        - a pageSize outside 1-11 is rejected, 11 is accepted
//   toggle-nonchinese - capability outputToSimplified true cannot make the
//                       toggle available when the host has no
//                       Traditional->Simplified transform for the engine's
//                       language (this manifest declares none)
//   dynamic-import-*  - dynamic import() is rejected, both for a module the
//                       static graph already loaded and for a loadable one
import { MARKER } from "/util.js";

console.log(`nav-languages ${JSON.stringify(navigator.languages)}`);
console.log(`manifest-name ${manifest.name}`);
console.log(`root-import ${MARKER}`);

// Ahead of the writes further down, so the key list is still exactly what
// the manifest seeded.
manifest.candidateWindow.expandable = false;
manifest.candidateWindow.macish = { expandable: true };
console.log(
  `cw-impl expandable=${String(manifest.candidateWindow.expandable)} ` +
    `moveOnExpand=${String(manifest.candidateWindow.moveOnExpand)} ` +
    `macish=${String(manifest.candidateWindow.macish)} ` +
    `fontSize=${String(manifest.candidateWindow.fontSize)} ` +
    `keys=${JSON.stringify(Object.keys(manifest.candidateWindow))}`,
);

// localStorage.key(index) is sorted alphabetically regardless of write order.
localStorage.clear();
localStorage.setItem("zebra", "1");
localStorage.setItem("apple", "1");
localStorage.setItem("mango", "1");
console.log(
  `key-order ${[localStorage.key(0), localStorage.key(1), localStorage.key(2)].join(",")}`,
);

// candidateWindow writes: valid ones stick, invalid ones are ignored (the
// previous value is kept, per the write-and-read-back contract).
manifest.candidateWindow.indexLabels = "12345";
manifest.candidateWindow.indexLabels = "あいう"; // not ASCII printable -> ignored
console.log(`indexlabels-after-bad ${manifest.candidateWindow.indexLabels}`);

manifest.candidateWindow.pageSize = 11; // boundary, valid
console.log(`pagesize-boundary ${manifest.candidateWindow.pageSize}`);
manifest.candidateWindow.pageSize = 20; // out of range (1-11) -> ignored
console.log(`pagesize-after-bad ${manifest.candidateWindow.pageSize}`);

manifest.candidateWindow.indexLabelDigitsRequireShift = true;
console.log(
  `requireshift-write ${String(manifest.candidateWindow.indexLabelDigitsRequireShift)}`,
);
manifest.candidateWindow.associatedModeIndexLabels = "shiftNumbers";
manifest.candidateWindow.associatedModeIndexLabels = "bogus"; // not one of the three -> ignored
manifest.candidateWindow.associatedModeIndexLabels = "system"; // retired token -> ignored
console.log(
  `assocmode-after-bad ${manifest.candidateWindow.associatedModeIndexLabels}`,
);

console.log(
  `toggle-nonchinese value=${String(manifest.toggle.outputToSimplified)} ` +
    `keys=${JSON.stringify(Object.keys(manifest.toggle))}`,
);

// Dynamic import() is outside the contract and must reject either way: the
// already-loaded specifier never reaches the module loader, the fresh one
// would load fine if it were allowed through.
const reportDynamicImport = (tag, specifier) =>
  import(specifier).then(
    () => console.log(`${tag} resolved`),
    (error) => console.log(`${tag} rejected ${error.message}`),
  );
reportDynamicImport("dynamic-import-loaded", "/util.js");
reportDynamicImport("dynamic-import-fresh", "/dynamic.js");

export default class {}
