// Load-time conformance checks for several small contract fixes, each logging
// a marker the test asserts on. Run under a controlled LANGUAGE so the locale
// checks are deterministic. Markers map to:
//   nav-languages    - navigator.languages carries the region->base chain
//   manifest-name     - a name locale-map with no match falls back to the
//                       lowest-sorted key, not the first-declared one
//   root-import       - a "/util.js" import resolves from the engine root
//   key-order         - localStorage.key(index) reports keys alphabetically
//   indexlabels-*     - a non-ASCII indexLabels write is rejected
//   pagesize-*        - a pageSize outside 1-11 is rejected, 11 is accepted
import { MARKER } from "/util.js";

console.log(`nav-languages ${JSON.stringify(navigator.languages)}`);
console.log(`manifest-name ${manifest.name}`);
console.log(`root-import ${MARKER}`);

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

export default class {}
