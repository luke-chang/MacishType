// Exercises the host-provided Intl.NumberFormat at load time and logs the
// results for the test to assert. en-US grouping/decimal glyphs are stable
// across ICU versions, so a few exact strings are asserted; part shapes are
// asserted by type, not localized value.

// Grouping and fraction digits.
console.log(
  `decimal ${new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 }).format(1234567.891)}`,
);

// Currency style.
console.log(
  `currency ${new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(1234.5)}`,
);

// Percent style multiplies by 100.
console.log(
  `percent ${new Intl.NumberFormat("en-US", { style: "percent" }).format(0.25)}`,
);

// BigInt keeps full precision (a double would round this).
console.log(`bigint ${new Intl.NumberFormat("en-US").format(12345678901234567890n)}`);

// Minimum fraction digits pad.
console.log(
  `minfrac ${new Intl.NumberFormat("en-US", { minimumFractionDigits: 2 }).format(5)}`,
);

// Grouping can be turned off.
console.log(
  `nogroup ${new Intl.NumberFormat("en-US", { useGrouping: false }).format(1234567)}`,
);

// signDisplay always shows a leading sign.
console.log(
  `sign ${new Intl.NumberFormat("en-US", { signDisplay: "always" }).format(5)}`,
);

// formatToParts of a grouped currency amount carries the expected part types.
const currencyParts = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
})
  .formatToParts(1234.5)
  .map((p) => p.type);
console.log(`currency-part-types ${JSON.stringify([...new Set(currencyParts)].sort())}`);

// A negative value produces a minusSign part.
const negTypes = new Intl.NumberFormat("en-US")
  .formatToParts(-5)
  .map((p) => p.type);
console.log(`has-minus-sign ${negTypes.indexOf("minusSign") !== -1}`);

// resolvedOptions reports the negotiated locale data and the style.
const resolved = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "usd",
}).resolvedOptions();
console.log(
  `resolved ${resolved.numberingSystem} ${resolved.style} ${resolved.currency}`,
);

// An invalid currency code is a RangeError.
let currencyError;
try {
  new Intl.NumberFormat("en-US", { style: "currency", currency: "US" });
  currencyError = "no-throw";
} catch (error) {
  currencyError = error.constructor.name;
}
console.log(`invalid-currency ${currencyError}`);

export default class {};
