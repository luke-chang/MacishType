// Exercises the host-provided Intl.PluralRules at load time and logs the
// results for the test to assert. Category names (one/two/few/many/other) are
// stable CLDR keywords, so they can be asserted exactly.

// English cardinal: only "one" and "other".
const enCardinal = new Intl.PluralRules("en");
console.log(
  `en-cardinal ${enCardinal.select(0)} ${enCardinal.select(1)} ${enCardinal.select(2)}`,
);

// English ordinal: one/two/few/other (1st, 2nd, 3rd, 4th).
const enOrdinal = new Intl.PluralRules("en", { type: "ordinal" });
console.log(
  `en-ordinal ${enOrdinal.select(1)} ${enOrdinal.select(2)} ${enOrdinal.select(3)} ${enOrdinal.select(4)}`,
);

// Fraction digits change the operands: "1.0" is no longer the "one" category.
console.log(
  `frac-affects ${new Intl.PluralRules("en", { minimumFractionDigits: 1 }).select(1)}`,
);

// A locale with richer categories exercises few/many.
const pl = new Intl.PluralRules("pl");
console.log(`pl-cardinal ${pl.select(2)} ${pl.select(5)}`);

// resolvedOptions lists the locale's categories for this type.
const resolved = enCardinal.resolvedOptions();
console.log(`categories ${JSON.stringify(resolved.pluralCategories.sort())}`);
console.log(`resolved-type ${new Intl.PluralRules("en", { type: "ordinal" }).resolvedOptions().type}`);

// An unknown type is a RangeError.
let typeError;
try {
  new Intl.PluralRules("en", { type: "nope" });
  typeError = "no-throw";
} catch (error) {
  typeError = error.constructor.name;
}
console.log(`invalid-type ${typeError}`);

export default class {};
