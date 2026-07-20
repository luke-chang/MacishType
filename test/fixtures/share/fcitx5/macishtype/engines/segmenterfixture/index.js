// Exercises the host-provided Intl.Segmenter (grapheme granularity) at load
// time and logs the results for the test to assert. Mirrors how a real
// engine counts user-perceived characters. Inputs are built from explicit
// code points so multi-codepoint clusters are unambiguous.
const cp = String.fromCodePoint;
const seg = new Intl.Segmenter(undefined, { granularity: "grapheme" });

const cases = {
  ascii: "abc", // 3
  combining: cp(0x65, 0x301), // e + combining acute -> 1
  astral: cp(0x1f600), // one astral codepoint -> 1
  zwj: cp(0x1f468, 0x200d, 0x1f469, 0x200d, 0x1f467), // family emoji -> 1
  flag: cp(0x1f1f9, 0x1f1fc), // regional-indicator pair -> 1
  hangulJamo: cp(0x1100, 0x1161), // conjoining jamo -> one syllable -> 1
  mixed: cp(0x61, 0x301, 0x62, 0x1f600), // a-acute, b, astral -> 3
};
const counts = {};
for (const key of Object.keys(cases)) {
  counts[key] = [...seg.segment(cases[key])].length;
}
console.log(`grapheme-counts ${JSON.stringify(counts)}`);

// Segment start indices are UTF-16 code units: a-acute(0), b(2), astral(3).
const indices = [...seg.segment(cases.mixed)].map((piece) => piece.index);
console.log(`grapheme-indices ${JSON.stringify(indices)}`);

// Unsupported granularities fail loudly rather than approximate.
let wordResult;
try {
  new Intl.Segmenter(undefined, { granularity: "word" });
  wordResult = "no-throw";
} catch (error) {
  wordResult = error.constructor.name;
}
console.log(`word-granularity ${wordResult}`);

console.log(
  `resolved ${JSON.stringify(new Intl.Segmenter("zh-Hant").resolvedOptions())}`,
);

export default class {};
