// Exercises the host-provided Intl.Collator at load time and logs the results
// for the test to assert. Comparisons are reported by sign (or exact 0), which
// is stable across ICU versions.
const sign = (n) => (n < 0 ? -1 : n > 0 ? 1 : 0);
const cp = String.fromCodePoint;
const aAcute = cp(0x61, 0x301); // "á"

// Base sensitivity ignores case and accents.
const base = new Intl.Collator("en", { sensitivity: "base" });
console.log(`base-case-equal ${base.compare("a", "A")}`);
console.log(`base-accent-equal ${base.compare("a", aAcute)}`);

// Accent sensitivity distinguishes accented letters.
const accent = new Intl.Collator("en", { sensitivity: "accent" });
console.log(`accent-distinguishes ${accent.compare("a", aAcute) !== 0}`);

// Numeric collation orders "10" after "9"; the default is codepoint-ish.
console.log(`numeric-order ${sign(new Intl.Collator("en", { numeric: true }).compare("10", "9"))}`);
console.log(`plain-order ${sign(new Intl.Collator("en").compare("10", "9"))}`);

// caseFirst upper sorts capitals first.
console.log(
  `casefirst-upper ${sign(new Intl.Collator("en", { caseFirst: "upper" }).compare("A", "a"))}`,
);

// A collator's compare is a valid Array#sort comparator.
const sorted = ["cherry", "Apple", "banana"].sort(new Intl.Collator("en").compare);
console.log(`sorted ${JSON.stringify(sorted)}`);

// resolvedOptions echoes the negotiated locale and options.
const resolved = new Intl.Collator("en", { numeric: true, sensitivity: "accent" }).resolvedOptions();
console.log(`resolved ${resolved.sensitivity} ${resolved.numeric} ${resolved.usage}`);

// An unknown sensitivity is a RangeError.
let error;
try {
  new Intl.Collator("en", { sensitivity: "nope" });
  error = "no-throw";
} catch (e) {
  error = e.constructor.name;
}
console.log(`invalid-sensitivity ${error}`);

export default class {};
