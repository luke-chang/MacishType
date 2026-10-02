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

// Options are read like any property, inherited ones included.
let inherited;
try {
  inherited = new Intl.NumberFormat(
    "en-US",
    Object.create({ style: "currency", currency: "USD" }),
  ).format(1);
} catch (error) {
  inherited = error.constructor.name;
}
console.log(`inherited-options ${inherited}`);

// Out-of-range values are a RangeError, including Object.prototype names and
// "uſd", which is ASCII only after toUpperCase.
const optionErrors = [
  ["NumberFormat", { style: "currency", currency: "USD", currencyDisplay: "constructor" }],
  ["NumberFormat", { roundingMode: "toString" }],
  ["PluralRules", { roundingMode: "toString" }],
  ["NumberFormat", { notation: "bogus" }],
  ["NumberFormat", { compactDisplay: "bogus" }],
  ["NumberFormat", { style: "" }],
  ["PluralRules", { type: "" }],
  ["NumberFormat", { style: "currency", currency: "uſd" }],
].map(([type, options]) => {
  try {
    new Intl[type]("en-US", options);
    return "no-throw";
  } catch (error) {
    return error.constructor.name;
  }
});
console.log(`invalid-option ${optionErrors.join(",")}`);

// Each option is read once, at construction.
let currencyDisplayReads = 0;
const counted = {
  style: "currency",
  currency: "USD",
  get currencyDisplay() {
    currencyDisplayReads++;
    return "code";
  },
};
const countedFormat = new Intl.NumberFormat("en-US", counted);
counted.currency = "EUR";
countedFormat.format(1);
const countedCurrency = countedFormat.resolvedOptions().currency;
console.log(`option-reads ${currencyDisplayReads} ${countedCurrency}`);

const outcome = (run) => {
  try {
    const result = run();
    return typeof result === "string" ? result : "ok";
  } catch (error) {
    return error.constructor.name;
  }
};

// Digit options follow ECMA-402: compact rounding, the currency's own digit
// count, halfExpand rounding, and option errors.
const digitOptions = [
  () => new Intl.NumberFormat("en-US", { notation: "compact" }).format(1234),
  () =>
    new Intl.NumberFormat("en-US", {
      style: "currency",
      currency: "USD",
      maximumFractionDigits: 0,
    }).format(1234.5),
  () => new Intl.NumberFormat("en-US", { style: "currency", currency: "JPY" }).format(1234),
  () => new Intl.NumberFormat("en-US", { maximumFractionDigits: 101 }),
  () => new Intl.NumberFormat("en-US", { minimumFractionDigits: 3, maximumFractionDigits: 1 }),
  () => new Intl.NumberFormat("en-US", { style: "currency" }),
].map(outcome);
console.log(`digit-options ${digitOptions.join("|")}`);

// A unit is validated before it reaches the ICU skeleton.
const groupingAndUnits = [
  () => new Intl.NumberFormat("en-US", { useGrouping: "false" }).format(12345),
  () => new Intl.NumberFormat("en-US", { useGrouping: "min2" }).format(1234),
  () => new Intl.NumberFormat("en-US", { useGrouping: 0 }).format(12345),
  () => new Intl.NumberFormat("en-US", { useGrouping: "bogus" }),
  () =>
    new Intl.NumberFormat("en-US", { style: "unit", unit: "kilometer-per-hour" }).format(50),
  () => new Intl.NumberFormat("en-US", { style: "unit", unit: "meter rounding-mode-floor" }),
].map(outcome);
console.log(`grouping-and-units ${groupingAndUnits.join("|")}`);

// The reported locale leaves out a numbering system the options added.
console.log(
  `reported-locale ${new Intl.NumberFormat("en-US", { numberingSystem: "arab" }).resolvedOptions().locale}`,
);

export default class {};
