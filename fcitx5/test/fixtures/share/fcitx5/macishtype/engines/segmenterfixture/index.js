// Exercises the host-provided Intl.Segmenter (grapheme, word, sentence) at
// load time and logs the results for the test to assert. Mirrors how a real
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

// containing(): offset 1 falls inside the a-acute cluster spanning [0, 2).
console.log(`containing-index ${seg.segment(cases.mixed).containing(1).index}`);

// Word granularity: ASCII word breaking is stable across ICU versions.
// Whitespace and punctuation runs are segments too but not word-like.
const wordSeg = new Intl.Segmenter("en", { granularity: "word" });
const wordLike = [...wordSeg.segment("The quick fox.")]
  .filter((piece) => piece.isWordLike)
  .map((piece) => piece.segment);
console.log(`word-like ${JSON.stringify(wordLike)}`);

// Sentence granularity: two sentences, and the pieces reconstruct the input.
const sentSeg = new Intl.Segmenter("en", { granularity: "sentence" });
const sentences = [...sentSeg.segment("Hello world. How are you?")].map(
  (piece) => piece.segment,
);
console.log(`sentence-count ${sentences.length}`);
console.log(`sentence-rejoin ${sentences.join("") === "Hello world. How are you?"}`);

// An unknown granularity still fails loudly rather than approximating.
let badResult;
try {
  new Intl.Segmenter(undefined, { granularity: "line" });
  badResult = "no-throw";
} catch (error) {
  badResult = error.constructor.name;
}
console.log(`bad-granularity ${badResult}`);

// An empty granularity is out of range too, not the default.
let emptyResult;
try {
  new Intl.Segmenter(undefined, { granularity: "" });
  emptyResult = "no-throw";
} catch (error) {
  emptyResult = error.constructor.name;
}
console.log(`empty-granularity ${emptyResult}`);

console.log(
  `resolved ${JSON.stringify(new Intl.Segmenter("zh-Hant").resolvedOptions())}`,
);

export default class {};
