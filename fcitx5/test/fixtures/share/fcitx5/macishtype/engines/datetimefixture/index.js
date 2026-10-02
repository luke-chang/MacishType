// Exercises the host-provided Intl.DateTimeFormat at load time and logs the
// results for the test to assert. Uses a fixed epoch and explicit time zones
// so formatting does not depend on the host machine's clock or zone.
// Assertions target structure and types, not localized glyphs, so they hold
// across ICU versions.
const EPOCH = 1704110400000; // 2024-01-01T12:00:00Z -> 07:00 in New York

// resolvedOptions() with no options: a valid locale/calendar/numbering plus
// the system IANA time zone (the value McBopomofo's timezone macros read).
const base = new Intl.DateTimeFormat("en-US").resolvedOptions();
console.log(`resolved-calendar ${base.calendar}`);
console.log(`resolved-numbering ${base.numberingSystem}`);
console.log(
  `resolved-timezone-nonempty ${typeof base.timeZone === "string" && base.timeZone.length > 0}`,
);

// Calling without `new` must also work (McBopomofo does this).
const tzNoNew = Intl.DateTimeFormat().resolvedOptions().timeZone;
console.log(`no-new-timezone-nonempty ${typeof tzNoNew === "string" && tzNoNew.length > 0}`);

// formatToParts carries the requested fields as typed parts.
const parts = new Intl.DateTimeFormat("en-US", {
  year: "numeric",
  month: "long",
  day: "numeric",
  timeZone: "America/New_York",
  timeZoneName: "short",
}).formatToParts(new Date(EPOCH));
const types = [...new Set(parts.map((p) => p.type))].sort();
console.log(`parts-types ${JSON.stringify(types)}`);

// A fixed epoch with an explicit zone formats deterministically.
const t24 = new Intl.DateTimeFormat("en-US", {
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
  timeZone: "America/New_York",
});
console.log(`format-24h ${t24.format(new Date(EPOCH))}`);
console.log(`resolved-hourcycle-24 ${t24.resolvedOptions().hourCycle}`);
console.log(`resolved-hour12-24 ${t24.resolvedOptions().hour12}`);

const t12 = new Intl.DateTimeFormat("en-US", {
  hour: "numeric",
  minute: "2-digit",
  hour12: true,
  timeZone: "America/New_York",
});
console.log(`format-12h-has-ampm ${/AM|PM/.test(t12.format(new Date(EPOCH)))}`);
console.log(`resolved-hourcycle-12 ${t12.resolvedOptions().hourCycle}`);

// dateStyle/timeStyle presets format without throwing.
const styled = new Intl.DateTimeFormat("en-US", {
  dateStyle: "medium",
  timeZone: "America/New_York",
});
console.log(`style-nonempty ${styled.format(new Date(EPOCH)).length > 0}`);

// Mixing a style with a component option is a TypeError.
let mixError;
try {
  new Intl.DateTimeFormat("en-US", { dateStyle: "short", year: "numeric" });
  mixError = "no-throw";
} catch (error) {
  mixError = error.constructor.name;
}
console.log(`style-component-mix ${mixError}`);

// An invalid time zone is a RangeError.
let tzError;
try {
  new Intl.DateTimeFormat("en-US", { timeZone: "Not/AZone" });
  tzError = "no-throw";
} catch (error) {
  tzError = error.constructor.name;
}
console.log(`invalid-tz ${tzError}`);

// McBopomofo's timezone macro, reproduced: locale zh-TW, generic zone name.
const tzName = new Intl.DateTimeFormat("zh-TW", {
  timeZone: "Asia/Taipei",
  timeZoneName: "longGeneric",
  hour: "2-digit",
})
  .formatToParts(new Date(EPOCH))
  .find((p) => p.type === "timeZoneName");
console.log(
  `tzname-longgeneric-found ${!!tzName && typeof tzName.value === "string" && tzName.value.length > 0}`,
);

// Each option is read once, resolvedOptions included.
let timeZoneReads = 0;
new Intl.DateTimeFormat("en-US", {
  get timeZone() {
    timeZoneReads++;
    return "UTC";
  },
}).resolvedOptions();
console.log(`timezone-reads ${timeZoneReads}`);

// The reported locale leaves out a calendar the options added, but keeps one
// the tag carried.
const reportedLocales = [
  new Intl.DateTimeFormat("en-US", { calendar: "japanese" }).resolvedOptions().locale,
  new Intl.DateTimeFormat("en-US-u-ca-japanese").resolvedOptions().locale,
];
console.log(`reported-locale ${reportedLocales.join("|")}`);

export default class {};
