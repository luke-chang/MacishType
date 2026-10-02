// Host-side glue evaluated before globals.js. Defines the bridge globals
// that are more convenient to express in JS than through the QuickJS C API;
// the primitive natives it builds on (__MacishTypeHost_*) are registered by
// the C++ host beforehand.
"use strict";

(function () {
  // Response for the engine-folder fetch(). Matches the macOS bridge:
  // body methods lock on entry so a second call rejects immediately, but
  // recoverable failures (UTF-8 decode) unlock so the engine can retry.
  function makeResponse(url, buffer) {
    let consumed = false;
    function lockBody() {
      if (consumed) {
        return Promise.reject(new Error("Body has already been consumed"));
      }
      consumed = true;
      return null;
    }
    return {
      ok: true,
      status: 200,
      url,
      text() {
        const locked = lockBody();
        if (locked) return locked;
        try {
          return Promise.resolve(__MacishTypeHost_utf8Decode(buffer));
        } catch (error) {
          consumed = false;
          return Promise.reject(new Error("Body is not valid UTF-8"));
        }
      },
      json() {
        return this.text().then(JSON.parse);
      },
      arrayBuffer() {
        const locked = lockBody();
        if (locked) return locked;
        return Promise.resolve(buffer.slice(0));
      },
    };
  }

  // The host owns fetch scheduling: the native resolves the path now
  // (invalid paths reject immediately) but reads the file on a worker
  // thread later, then calls makeResponse + resolve back on the JS thread.
  __MacishTypeHost_registerMakeResponse(makeResponse);

  globalThis.__MacishType_fetch = function (input, resolve, reject) {
    __MacishTypeHost_beginFetch(String(input), resolve, reject);
  };

  // Assembles the event object handed to engine hooks. `data` is built by
  // the C++ session per invocation; mutators queue through the
  // __MacishTypeHost_action dispatcher and apply after the hook returns.
  // Each passes its own event first: the dispatcher acts only for the event
  // of the hook running now.
  const digitKeyPattern = /^(?:Digit|Numpad)([0-9])$/;

  globalThis.__MacishTypeHost_makeEvent = function (data) {
    const event = Object.assign({}, data.fields);
    const states = data.modifierStates || {};
    event.getModifierState = (name) => states[name] === true;

    const cw = data.candidateWindow;
    const digitsRequireShift = cw.indexLabelDigitsRequireShift === true;
    // indexLabels is contract-validated ASCII printable, so code-unit
    // indices are character indices.
    const lookupLabel = (label) => {
      const index = cw.indexLabels.indexOf(label);
      return index < 0 || index >= cw.pageSize ? null : index;
    };
    const matchCharacter = (text) => {
      if (typeof text !== "string" || text.length === 0) return null;
      // Only the first character is looked up, never a whitespace one (a
      // " " label is a blank slot: it reserves the position but is not
      // selectable).
      const first = Array.from(text)[0];
      if (/\s/u.test(first)) return null;
      // A bare character carries no keystroke identity, so digit labels
      // never match through it while the Shift requirement is on.
      if (digitsRequireShift && first >= "0" && first <= "9") return null;
      return lookupLabel(first);
    };
    event.candidateWindow = {
      isVisible: cw.isVisible,
      indexLabels: cw.indexLabels,
      pageSize: cw.pageSize,
      layoutDirection: cw.layoutDirection,
      handleNavigationKeys: cw.handleNavigationKeys,
      handleIndexLabelKeys: cw.handleIndexLabelKeys,
      indexLabelDigitsRequireShift: digitsRequireShift,
      pageStart: cw.pageStart,
      pageEnd: cw.pageEnd,
      candidateIndex(value) {
        if (typeof value === "string") return matchCharacter(value);
        if (!value || typeof value !== "object") return null;
        // Option-modified keys never select, mirroring the host dispatch.
        if (value.altKey === true) return null;
        // Physical digit keys — main row or keypad; the key's digit looks
        // itself up in the labels, independent of layout.
        const digitMatch = digitKeyPattern.exec(value.code || "");
        if (digitsRequireShift && digitMatch) {
          return value.shiftKey === true ? lookupLabel(digitMatch[1]) : null;
        }
        // Named keys ("Enter", "Tab") are not label characters.
        const key = value.key;
        if (typeof key !== "string" || Array.from(key).length !== 1) return null;
        return matchCharacter(key);
      },
      // Mirrors the host's nav-key table (dispatchCandidateWindowKey) for
      // engines that opt out of handleNavigationKeys. Tab is the only nav
      // key that reads a modifier (Shift, to reverse) and the only one that
      // wraps; Option — or Shift on any other key — disqualifies the key,
      // leaving it to the engine.
      navigationIntent(keyEvent) {
        if (!keyEvent || typeof keyEvent !== "object") return null;
        if (keyEvent.altKey === true) return null;
        if (keyEvent.code === "Tab") {
          return {
            direction:
              keyEvent.shiftKey === true ? "itemBackward" : "itemForward",
            options: { wrapping: true },
          };
        }
        if (keyEvent.shiftKey === true) return null;
        switch (keyEvent.code) {
          case "ArrowUp": return { direction: "up" };
          case "ArrowDown": return { direction: "down" };
          case "ArrowLeft": return { direction: "left" };
          case "ArrowRight": return { direction: "right" };
          case "PageUp": return { direction: "pageUp" };
          case "PageDown": return { direction: "pageDown" };
          case "Home": return { direction: "home" };
          case "End": return { direction: "end" };
          default:
            return null;
        }
      },
    };

    const act = globalThis.__MacishTypeHost_action;
    event.updateMarkedText = (text, options) => {
      act(event, "updateMarkedText", text, options);
    };
    event.updateCandidates = (items, options) => {
      act(event, "updateCandidates", items, options);
    };
    event.updateMessage = (text, options) => {
      act(event, "updateMessage", text, options);
    };
    event.commit = (candidate) => {
      act(event, "commit", candidate);
    };
    event.commitSelectedCandidate = () => {
      act(event, "commitSelectedCandidate");
    };
    event.commitCandidateAtIndex = (index) => {
      act(event, "commitCandidateAtIndex", index);
    };
    event.navigateCandidates = (direction, options) => {
      act(event, "navigateCandidates", direction, options);
    };
    event.resetContext = () => {
      act(event, "resetContext");
    };
    event.flushStaged = (append) => {
      act(event, "flushStaged", append);
    };
    event.enterAssociatedMode = (heldChar, candidates) => {
      act(event, "enterAssociatedMode", heldChar, candidates);
    };
    // One sound per event: repeat calls collapse.
    let beeped = false;
    event.beep = () => {
      if (beeped) return;
      beeped = true;
      act(event, "beep");
    };
    return event;
  };

  // Intl.Segmenter. macOS engines get this from JavaScriptCore; quickjs-ng
  // ships no Intl at all, so synthesize the standard API over ICU's UAX #29
  // break iterators (grapheme, word, sentence). The native returns boundary
  // offsets in UTF-16 code units, so `index` matches JavaScriptCore's.
  const intl = globalThis.Intl || (globalThis.Intl = {});

  // ECMA-402 CanonicalizeLocaleList: a string or an array-like read by index,
  // each entry a string or an object, each tag well formed.
  function requestedLocales(locales) {
    if (locales === undefined) return [];
    if (locales === null) {
      throw new TypeError("Cannot convert null to a locale list");
    }
    const entries = typeof locales === "string" ? [locales] : Object(locales);
    const length = Math.min(Math.max(Math.trunc(entries.length) || 0, 0),
      Number.MAX_SAFE_INTEGER);
    const tags = [];
    for (let index = 0; index < length; index++) {
      if (!(index in entries)) continue;
      const entry = entries[index];
      if (typeof entry !== "string" && Object(entry) !== entry) {
        throw new TypeError("Locale list entries must be strings or objects");
      }
      const tag = String(entry);
      if (!__MacishTypeHost_intlWellFormedTag(tag)) {
        throw new RangeError(`Incorrect locale information provided: ${tag}`);
      }
      tags.push(tag);
    }
    return tags;
  }

  // ECMA-402 locale resolution with the lookup matcher: the first requested
  // tag ICU has data for, else the first such tag among the host's preferred
  // languages (the default locale), else "en". navigator is read per call:
  // globals.js defines it after this script runs.
  function resolveLocale(locales) {
    for (const tag of requestedLocales(locales)) {
      if (__MacishTypeHost_intlSupportedLocale(tag)) {
        return tag;
      }
    }
    for (const tag of navigator.languages) {
      if (__MacishTypeHost_intlSupportedLocale(tag)) {
        return tag;
      }
    }
    return "en";
  }

  // ECMA-402 CoerceOptionsToObject: undefined means no options, and null
  // throws as ToObject(null) does.
  function optionsObject(options) {
    if (options === null) {
      throw new TypeError("Cannot convert null to an options object");
    }
    return options === undefined ? {} : Object(options);
  }

  function makeSegments(locale, granularity, input) {
    const { boundaries, wordLike } = __MacishTypeHost_intlSegment(
      locale,
      granularity,
      input,
    );
    const count = boundaries.length > 0 ? boundaries.length - 1 : 0;
    const record = (i) => {
      const seg = {
        segment: input.slice(boundaries[i], boundaries[i + 1]),
        index: boundaries[i],
        input,
      };
      if (wordLike) seg.isWordLike = wordLike[i];
      return seg;
    };
    return {
      [Symbol.iterator]() {
        let i = 0;
        return {
          next() {
            return i < count
              ? { value: record(i++), done: false }
              : { value: undefined, done: true };
          },
        };
      },
      containing(index) {
        const at = Math.trunc(Number(index) || 0);
        if (at < 0 || at >= input.length) return undefined;
        // Largest i with boundaries[i] <= at; the spans cover [0, length).
        let lo = 0;
        let hi = count - 1;
        while (lo < hi) {
          const mid = (lo + hi + 1) >> 1;
          if (boundaries[mid] <= at) lo = mid;
          else hi = mid - 1;
        }
        return record(lo);
      },
    };
  }

  intl.Segmenter = function Segmenter(locales, options) {
    if (!(this instanceof Segmenter)) {
      throw new TypeError("Constructor Intl.Segmenter requires 'new'");
    }
    if (options !== undefined && Object(options) !== options) {
      throw new TypeError("Intl.Segmenter options must be an object");
    }
    const granularity =
      optionReader("Segmenter", options ?? {}).choice("granularity", [
        "grapheme",
        "word",
        "sentence",
      ]) ?? "grapheme";
    const locale = resolveLocale(locales);
    this.segment = (input) => makeSegments(locale, granularity, String(input));
    this.resolvedOptions = () => ({ locale, granularity });
  };

  // Intl.DateTimeFormat. ECMA-402 options are normalized to a CLDR skeleton
  // here; ICU builds the locale pattern and formats through the host natives.
  // Covers the common option set (component fields, dateStyle/timeStyle,
  // hour12/hourCycle, timeZone, timeZoneName) — enough for the contract's date
  // and timezone macros. macOS engines get this from JavaScriptCore.
  const DTF_STYLE = { full: 0, long: 1, medium: 2, short: 3 };
  const DTF_TZNAME = {
    short: "z",
    long: "zzzz",
    shortOffset: "O",
    longOffset: "OOOO",
    shortGeneric: "v",
    longGeneric: "vvvv",
  };

  // `allowed` is a list of values or a table keyed by them.
  function enumOption(type, name, value, allowed) {
    if (value === undefined) return undefined;
    const s = String(value);
    const known = Array.isArray(allowed)
      ? allowed.includes(s)
      : Object.hasOwn(allowed, s);
    if (!known) {
      throw new RangeError(
        "Value " +
          s +
          " out of range for Intl." +
          type +
          " options property " +
          name,
      );
    }
    return s;
  }

  // ECMA-402 DefaultNumberOption.
  function numberOption(type, name, value, lo, hi, fallback) {
    if (value === undefined) return fallback;
    const n = Number(value);
    if (isNaN(n) || n < lo || n > hi) {
      throw new RangeError(name + " value is out of range for Intl." + type);
    }
    return Math.floor(n);
  }

  // Reads the options `o` of one Intl.<type> constructor; an option omitted
  // reads as undefined.
  function optionReader(type, o) {
    return {
      choice: (name, allowed) => enumOption(type, name, o[name], allowed),
      number: (name, lo, hi, fallback) =>
        numberOption(type, name, o[name], lo, hi, fallback),
      string(name) {
        const value = o[name];
        return value === undefined ? undefined : String(value);
      },
      flag(name) {
        const value = o[name];
        return value === undefined ? undefined : !!value;
      },
    };
  }

  // Appends Unicode extension keywords, given as key, value, ..., to a tag.
  function withExtensions(tag, keywords) {
    if (keywords.length === 0) return tag;
    return tag + (/-u-/.test(tag) ? "-" : "-u-") + keywords.join("-");
  }

  // The locale resolvedOptions reports: `reportedTag` leaves out the
  // extensions that only the options added, so resolve it separately when it
  // differs from the tag ICU was given.
  function reportedLocale(reportedTag, localeTag, resolvedLocale) {
    return reportedTag === localeTag
      ? resolvedLocale
      : __MacishTypeHost_intlResolveLocale(reportedTag).locale;
  }

  function dtfHourLetter(o) {
    if (o.hour12 !== undefined) return o.hour12 ? "h" : "H";
    if (o.hourCycle) return { h11: "K", h12: "h", h23: "H", h24: "k" }[o.hourCycle];
    return "j"; // the locale's preferred hour cycle
  }

  function dtfSkeleton(o) {
    let s = "";
    if (o.weekday) s += "E".repeat({ narrow: 5, short: 3, long: 4 }[o.weekday]);
    if (o.era) s += "G".repeat({ narrow: 5, short: 3, long: 4 }[o.era]);
    if (o.year) s += o.year === "2-digit" ? "yy" : "y";
    if (o.month)
      s += { numeric: "M", "2-digit": "MM", narrow: "MMMMM", short: "MMM", long: "MMMM" }[
        o.month
      ];
    if (o.day) s += o.day === "2-digit" ? "dd" : "d";
    if (o.hour) {
      const h = dtfHourLetter(o);
      s += o.hour === "2-digit" ? h + h : h;
    }
    if (o.minute) s += o.minute === "2-digit" ? "mm" : "m";
    if (o.second) s += o.second === "2-digit" ? "ss" : "s";
    if (o.fractionalSecondDigits) s += "S".repeat(o.fractionalSecondDigits);
    if (o.dayPeriod) s += "B".repeat({ narrow: 5, short: 1, long: 4 }[o.dayPeriod]);
    if (o.timeZoneName) s += DTF_TZNAME[o.timeZoneName];
    return s;
  }

  // Every option DateTimeFormat reads, in ECMA-402's order; one missing here
  // never reaches the constructor.
  const DTF_OPTIONS = ["calendar", "numberingSystem", "hour12", "hourCycle",
    "timeZone", "weekday", "era", "year", "month", "day", "dayPeriod", "hour",
    "minute", "second", "fractionalSecondDigits", "timeZoneName", "dateStyle",
    "timeStyle"];

  // ECMA-402 ToDateTimeOptions: the fields a formatter shows when the caller
  // names none of the kind it requires.
  const DATE_FIELDS = ["weekday", "year", "month", "day"];
  const TIME_FIELDS = ["dayPeriod", "hour", "minute", "second",
    "fractionalSecondDigits"];
  function dateTimeOptions(options, required, defaults) {
    const source = optionsObject(options);
    const adjusted = {};
    for (const name of DTF_OPTIONS) {
      const value = source[name];
      if (value !== undefined) adjusted[name] = value;
    }
    if (required === "date" && adjusted.timeStyle !== undefined) {
      throw new TypeError("Invalid option : timeStyle");
    }
    if (required === "time" && adjusted.dateStyle !== undefined) {
      throw new TypeError("Invalid option : dateStyle");
    }
    const named = (fields) =>
      fields.some((field) => adjusted[field] !== undefined);
    const needDefaults =
      adjusted.dateStyle === undefined &&
      adjusted.timeStyle === undefined &&
      (required === "time" || !named(DATE_FIELDS)) &&
      (required === "date" || !named(TIME_FIELDS));
    if (needDefaults) {
      const fields = [];
      if (defaults !== "time") fields.push("year", "month", "day");
      if (defaults !== "date") fields.push("hour", "minute", "second");
      for (const field of fields) adjusted[field] = "numeric";
    }
    return adjusted;
  }

  intl.DateTimeFormat = function DateTimeFormat(locales, options) {
    // Callable with or without `new`, per ECMA-402.
    const self =
      this instanceof intl.DateTimeFormat
        ? this
        : Object.create(intl.DateTimeFormat.prototype);
    const o = dateTimeOptions(options, "any", "date");
    const { choice, number, flag, string } = optionReader("DateTimeFormat", o);

    const weekday = choice("weekday", ["narrow", "short", "long"]);
    const era = choice("era", ["narrow", "short", "long"]);
    const year = choice("year", ["numeric", "2-digit"]);
    const month = choice("month", [
      "numeric",
      "2-digit",
      "narrow",
      "short",
      "long",
    ]);
    const day = choice("day", ["numeric", "2-digit"]);
    const hour = choice("hour", ["numeric", "2-digit"]);
    const minute = choice("minute", ["numeric", "2-digit"]);
    const second = choice("second", ["numeric", "2-digit"]);
    const dayPeriod = choice("dayPeriod", ["narrow", "short", "long"]);
    const timeZoneName = choice("timeZoneName", DTF_TZNAME);
    const hourCycle = choice("hourCycle", ["h11", "h12", "h23", "h24"]);
    const dateStyle = choice("dateStyle", DTF_STYLE);
    const timeStyle = choice("timeStyle", DTF_STYLE);
    const fractionalSecondDigits = number("fractionalSecondDigits", 1, 3);
    const hour12 = flag("hour12");

    const hasComponent = !!(
      weekday ||
      era ||
      year ||
      month ||
      day ||
      hour ||
      minute ||
      second ||
      dayPeriod ||
      timeZoneName ||
      fractionalSecondDigits !== undefined
    );
    if ((dateStyle || timeStyle) && hasComponent) {
      throw new TypeError(
        "Intl.DateTimeFormat: dateStyle/timeStyle cannot be combined with " +
          "explicit date-time component options",
      );
    }

    const comp = {
      weekday,
      era,
      year,
      month,
      day,
      hour,
      minute,
      second,
      dayPeriod,
      timeZoneName,
      fractionalSecondDigits,
      hour12,
      hourCycle,
    };
    const skeleton = dateStyle || timeStyle ? "" : dtfSkeleton(comp);

    const ext = [];
    if (o.calendar) ext.push("ca", String(o.calendar));
    if (o.numberingSystem) ext.push("nu", String(o.numberingSystem));
    const baseTag = resolveLocale(locales);
    const localeTag = withExtensions(baseTag, ext);

    const timeZone = string("timeZone") ?? "";
    const resolved = __MacishTypeHost_intlDateTimeResolve(
      localeTag,
      skeleton,
      timeZone,
      dateStyle ? DTF_STYLE[dateStyle] : -1,
      timeStyle ? DTF_STYLE[timeStyle] : -1,
    );
    if (!resolved.ok) {
      if (resolved.error === "invalid-timezone") {
        throw new RangeError("Invalid time zone specified: " + timeZone);
      }
      throw new Error("Intl.DateTimeFormat: " + (resolved.error || "failed"));
    }
    const pattern = resolved.pattern;

    const toEpoch = (date) => {
      const ms = date === undefined ? Date.now() : Number(date);
      if (!isFinite(ms)) throw new RangeError("Invalid time value");
      return ms;
    };

    self.format = (date) =>
      __MacishTypeHost_intlDateTimeFormat(localeTag, pattern, resolved.timeZone, toEpoch(date));
    self.formatToParts = (date) =>
      __MacishTypeHost_intlDateTimeFormatToParts(
        localeTag,
        pattern,
        resolved.timeZone,
        toEpoch(date),
      );
    self.resolvedOptions = () => {
      const r = {
        locale: reportedLocale(baseTag, localeTag, resolved.locale),
        calendar: resolved.calendar,
        numberingSystem: resolved.numberingSystem,
        timeZone: resolved.timeZone,
      };
      if (resolved.hourCycle) {
        r.hourCycle = resolved.hourCycle;
        r.hour12 = resolved.hourCycle === "h11" || resolved.hourCycle === "h12";
      }
      if (dateStyle) r.dateStyle = dateStyle;
      if (timeStyle) r.timeStyle = timeStyle;
      const echo = [
        "weekday",
        "era",
        "year",
        "month",
        "day",
        "hour",
        "minute",
        "second",
        "dayPeriod",
        "timeZoneName",
      ];
      for (const key of echo) if (comp[key]) r[key] = comp[key];
      if (comp.fractionalSecondDigits !== undefined)
        r.fractionalSecondDigits = comp.fractionalSecondDigits;
      return r;
    };
    return self;
  };

  // Intl.NumberFormat. ECMA-402 options compile to an ICU number skeleton
  // (which also serves as the format cache key); the number crosses to the
  // host as a decimal string so BigInt and large integers keep full
  // precision. macOS engines get this from JavaScriptCore.
  const NF_ROUNDING = {
    ceil: "rounding-mode-ceiling",
    floor: "rounding-mode-floor",
    expand: "rounding-mode-up",
    trunc: "rounding-mode-down",
    halfCeil: "rounding-mode-half-ceiling",
    halfFloor: "rounding-mode-half-floor",
    halfExpand: "rounding-mode-half-up",
    halfTrunc: "rounding-mode-half-down",
    halfEven: "rounding-mode-half-even",
  };
  const NF_CURRENCY_DISPLAY = {
    code: "unit-width-iso-code",
    name: "unit-width-full-name",
    narrowSymbol: "unit-width-narrow",
    symbol: "",
  };
  const NF_UNIT_DISPLAY = {
    long: "unit-width-full-name",
    narrow: "unit-width-narrow",
    short: "",
  };
  const NF_SIGN_DISPLAY = {
    always: "sign-always",
    never: "sign-never",
    exceptZero: "sign-except-zero",
    negative: "sign-negative",
    auto: "",
  };
  const NF_UNITS = new Set(["acre", "bit", "byte", "celsius", "centimeter",
    "day", "degree", "fahrenheit", "fluid-ounce", "foot", "gallon", "gigabit",
    "gigabyte", "gram", "hectare", "hour", "inch", "kilobit", "kilobyte",
    "kilogram", "kilometer", "liter", "megabit", "megabyte", "meter",
    "microsecond", "mile", "mile-scandinavian", "milliliter", "millimeter",
    "millisecond", "minute", "month", "nanosecond", "ounce", "percent",
    "petabyte", "pound", "second", "stone", "terabit", "terabyte", "week",
    "yard", "year"]);

  // ECMA-402 IsWellFormedUnitIdentifier; NF_UNITS is its sanctioned list.
  function nfWellFormedUnit(unit) {
    const [numerator, denominator, ...rest] = unit.split("-per-");
    return (
      NF_UNITS.has(numerator) &&
      (denominator === undefined || NF_UNITS.has(denominator)) &&
      rest.length === 0
    );
  }

  // ECMA-402 GetBooleanOrStringNumberFormatOption for useGrouping.
  function nfUseGrouping(value, fallback) {
    if (value === undefined) return fallback;
    if (value === true) return "always";
    if (!value) return false;
    const s = String(value);
    if (s === "true" || s === "false") return fallback;
    return enumOption("NumberFormat", "useGrouping", s, [
      "min2",
      "auto",
      "always",
    ]);
  }

  // ECMA-402 SetNumberFormatDigitOptions. With compact notation and no digit
  // options, ICU's default compact precision is ECMA-402's compact rounding.
  function nfDigitOptions(o, type, mnfdDefault, mxfdDefault, notation) {
    const digits = {
      minimumIntegerDigits: numberOption(
        type,
        "minimumIntegerDigits",
        o.minimumIntegerDigits,
        1,
        21,
        1,
      ),
    };
    let mnfd = o.minimumFractionDigits;
    let mxfd = o.maximumFractionDigits;
    const mnsd = o.minimumSignificantDigits;
    const mxsd = o.maximumSignificantDigits;
    digits.roundingMode = enumOption(
      type,
      "roundingMode",
      o.roundingMode,
      NF_ROUNDING,
    );
    if (mnsd !== undefined || mxsd !== undefined) {
      const min = numberOption(
        type,
        "minimumSignificantDigits",
        mnsd,
        1,
        21,
        1,
      );
      digits.minimumSignificantDigits = min;
      digits.maximumSignificantDigits = numberOption(
        type,
        "maximumSignificantDigits",
        mxsd,
        min,
        21,
        21,
      );
    } else if (mnfd !== undefined || mxfd !== undefined) {
      mnfd = numberOption(type, "minimumFractionDigits", mnfd, 0, 100);
      mxfd = numberOption(type, "maximumFractionDigits", mxfd, 0, 100);
      if (mnfd === undefined) mnfd = Math.min(mnfdDefault, mxfd);
      else if (mxfd === undefined) mxfd = Math.max(mxfdDefault, mnfd);
      else if (mnfd > mxfd) {
        throw new RangeError(
          "maximumFractionDigits value is out of range for Intl." + type,
        );
      }
      digits.minimumFractionDigits = mnfd;
      digits.maximumFractionDigits = mxfd;
    } else if (notation !== "compact") {
      digits.minimumFractionDigits = mnfdDefault;
      digits.maximumFractionDigits = mxfdDefault;
    }
    return digits;
  }

  // ECMA-402 CurrencyDigits. ICU's default currency precision is the
  // currency's own digit count, so read it off a formatted zero.
  const currencyDigitsByCode = new Map();
  function nfCurrencyDigits(currency) {
    let digits = currencyDigitsByCode.get(currency);
    if (digits === undefined) {
      const fraction = __MacishTypeHost_intlNumberFormatToParts(
        "und",
        "currency/" + currency,
        "0",
      ).find((part) => part.type === "fraction");
      digits = fraction ? fraction.value.length : 0;
      currencyDigitsByCode.set(currency, digits);
    }
    return digits;
  }

  function nfNumberString(value) {
    if (typeof value === "bigint") return value.toString();
    if (typeof value === "string") return value.trim();
    return String(Number(value));
  }

  // Enum values in record are validated, so the tables are only indexed by
  // own keys.
  function nfSkeleton(record) {
    const tokens = [];
    if (record.style === "percent") {
      tokens.push("percent", "scale/100");
    } else if (record.style === "currency") {
      tokens.push("currency/" + record.currency);
      const width = NF_CURRENCY_DISPLAY[record.currencyDisplay];
      if (width) tokens.push(width);
    } else if (record.style === "unit") {
      tokens.push("unit/" + record.unit);
      const width = NF_UNIT_DISPLAY[record.unitDisplay];
      if (width) tokens.push(width);
    }

    if (record.notation === "scientific") tokens.push("scientific");
    else if (record.notation === "engineering") tokens.push("engineering");
    else if (record.notation === "compact")
      tokens.push(
        record.compactDisplay === "long" ? "compact-long" : "compact-short",
      );

    if (record.minimumSignificantDigits !== undefined) {
      const min = record.minimumSignificantDigits;
      const max = record.maximumSignificantDigits;
      tokens.push("@".repeat(min) + "#".repeat(max - min));
    } else if (record.minimumFractionDigits !== undefined) {
      const min = record.minimumFractionDigits;
      const max = record.maximumFractionDigits;
      if (max === 0) tokens.push("precision-integer");
      else tokens.push("." + "0".repeat(min) + "#".repeat(max - min));
    }

    if (record.minimumIntegerDigits > 1) {
      tokens.push("integer-width/+" + "0".repeat(record.minimumIntegerDigits));
    }

    if (record.useGrouping === false) tokens.push("group-off");
    else if (record.useGrouping === "always") tokens.push("group-on-aligned");
    else if (record.useGrouping === "min2") tokens.push("group-min2");

    const sign = NF_SIGN_DISPLAY[record.signDisplay ?? "auto"];
    if (sign) tokens.push(sign);
    tokens.push(NF_ROUNDING[record.roundingMode ?? "halfExpand"]);

    return tokens.join(" ");
  }

  intl.NumberFormat = function NumberFormat(locales, options) {
    const self =
      this instanceof intl.NumberFormat
        ? this
        : Object.create(intl.NumberFormat.prototype);
    const o = optionsObject(options);
    const { choice, string } = optionReader("NumberFormat", o);
    const numberingSystem = string("numberingSystem");
    const style =
      choice("style", ["decimal", "percent", "currency", "unit"]) ??
      "decimal";
    const currencyOption = string("currency");
    if (
      currencyOption !== undefined &&
      !/^[A-Za-z]{3}$/.test(currencyOption)
    ) {
      throw new RangeError("Invalid currency code: " + currencyOption);
    }
    const currency = currencyOption?.toUpperCase();
    const currencyDisplay =
      choice("currencyDisplay", NF_CURRENCY_DISPLAY) ?? "symbol";
    const unit = string("unit");
    if (unit !== undefined && !nfWellFormedUnit(unit)) {
      throw new RangeError("Invalid unit argument: " + unit);
    }
    const unitDisplay = choice("unitDisplay", NF_UNIT_DISPLAY) ?? "short";
    if (style === "currency" && currency === undefined) {
      throw new TypeError("Currency code is required with currency style.");
    }
    if (style === "unit" && unit === undefined) {
      throw new TypeError("unit style requires a unit");
    }
    const notation = choice("notation", [
      "standard",
      "scientific",
      "engineering",
      "compact",
    ]);
    const currencyDigits =
      style === "currency" && (notation ?? "standard") === "standard"
        ? nfCurrencyDigits(currency)
        : undefined;
    const record = {
      style,
      currency,
      currencyDisplay,
      unit,
      unitDisplay,
      notation,
      ...nfDigitOptions(
        o,
        "NumberFormat",
        currencyDigits ?? 0,
        currencyDigits ?? (style === "percent" ? 0 : 3),
        notation,
      ),
      compactDisplay: choice("compactDisplay", ["short", "long"]),
      useGrouping: nfUseGrouping(
        o.useGrouping,
        notation === "compact" ? "min2" : "auto",
      ),
      signDisplay: choice("signDisplay", NF_SIGN_DISPLAY),
    };
    const skeleton = nfSkeleton(record);

    const baseTag = resolveLocale(locales);
    const localeTag = withExtensions(
      baseTag,
      numberingSystem ? ["nu", numberingSystem] : [],
    );
    const resolved = __MacishTypeHost_intlResolveLocale(localeTag);

    self.format = (value) =>
      __MacishTypeHost_intlNumberFormat(localeTag, skeleton, nfNumberString(value));
    self.formatToParts = (value) =>
      __MacishTypeHost_intlNumberFormatToParts(
        localeTag,
        skeleton,
        nfNumberString(value),
      );
    self.resolvedOptions = () => {
      const r = {
        locale: reportedLocale(baseTag, localeTag, resolved.locale),
        numberingSystem: resolved.numberingSystem,
        style,
      };
      if (style === "currency") {
        r.currency = record.currency;
        r.currencyDisplay = record.currencyDisplay;
      }
      if (style === "unit") {
        r.unit = record.unit;
        r.unitDisplay = record.unitDisplay;
      }
      if (record.notation) r.notation = record.notation;
      if (record.signDisplay) r.signDisplay = record.signDisplay;
      r.useGrouping = record.useGrouping;
      return r;
    };
    return self;
  };

  // Intl.PluralRules. Reuses NumberFormat's skeleton builder so the digit
  // options shape the operands, then defers category selection to ICU.
  intl.PluralRules = function PluralRules(locales, options) {
    const self =
      this instanceof intl.PluralRules
        ? this
        : Object.create(intl.PluralRules.prototype);
    const o = optionsObject(options);
    const type =
      optionReader("PluralRules", o).choice("type", ["cardinal", "ordinal"]) ??
      "cardinal";
    const typeCode = type === "ordinal" ? 1 : 0;
    const skeleton = nfSkeleton(
      nfDigitOptions(o, "PluralRules", 0, 3, "standard"),
    );

    const localeTag = resolveLocale(locales);
    const resolved = __MacishTypeHost_intlResolveLocale(localeTag);

    self.select = (value) =>
      __MacishTypeHost_intlPluralSelect(localeTag, typeCode, skeleton, nfNumberString(value));
    self.resolvedOptions = () => ({
      locale: resolved.locale,
      type,
      pluralCategories: __MacishTypeHost_intlPluralCategories(localeTag, typeCode),
    });
    return self;
  };

  // Intl.Collator. ECMA-402 options collapse to a strength/case/numeric
  // signature that both configures ICU's collator and keys its cache; compare
  // then defers to ucol_strcoll. macOS engines get this from JavaScriptCore.
  // Indexed by the caseFirst code the collator signature carries.
  const COLLATOR_CASE_FIRST = ["false", "upper", "lower"];

  intl.Collator = function Collator(locales, options) {
    const self =
      this instanceof intl.Collator
        ? this
        : Object.create(intl.Collator.prototype);
    const o = optionsObject(options);

    const { choice, flag } = optionReader("Collator", o);
    const usage = choice("usage", ["sort", "search"]) ?? "sort";
    const collationOption = o.collation;
    const collation = collationOption ? String(collationOption) : undefined;
    const numeric = flag("numeric");
    const caseFirst = choice("caseFirst", COLLATOR_CASE_FIRST);
    const sensitivity =
      choice("sensitivity", ["base", "accent", "case", "variant"]) ??
      "variant";
    const ignorePunctuation = flag("ignorePunctuation");

    // sensitivity → (strength, case level).
    let strength = 2; // variant -> tertiary
    let caseLevel = 0;
    if (sensitivity === "base") strength = 0;
    else if (sensitivity === "accent") strength = 1;
    else if (sensitivity === "case") {
      strength = 0;
      caseLevel = 1;
    }
    // -1 leaves an option the caller did not give to the locale's default.
    const tri = (value) => (value === undefined ? -1 : value ? 1 : 0);
    const cf = COLLATOR_CASE_FIRST.indexOf(caseFirst);
    const signature = [
      strength,
      caseLevel,
      tri(numeric),
      cf,
      tri(ignorePunctuation),
    ].join(",");

    const baseTag = resolveLocale(locales);
    const reportedTag = withExtensions(
      baseTag,
      collation ? ["co", collation] : [],
    );
    const localeTag =
      usage === "search"
        ? withExtensions(baseTag, ["co", "search"])
        : reportedTag;
    const resolved = __MacishTypeHost_intlResolveLocale(localeTag);

    self.compare = (a, b) =>
      __MacishTypeHost_intlCollatorCompare(localeTag, signature, String(a), String(b));
    self.resolvedOptions = () => ({
      locale: reportedLocale(reportedTag, localeTag, resolved.locale),
      usage,
      sensitivity,
      numeric: numeric ?? false,
      caseFirst: caseFirst ?? "false",
      ignorePunctuation: ignorePunctuation ?? false,
      collation: collation ?? "default",
    });
    return self;
  };

  // With Intl present, ECMA-402 routes the locale-sensitive built-ins through
  // it; quickjs-ng's own versions ignore locales. Without options a call
  // reuses its formatter until the preferred languages change, so a sort
  // comparator does not build one per pair.
  const cachedFormatters = new Map();
  function localeFormatter(key, Constructor, locales, options,
    adjust = (given) => given) {
    if (options !== undefined ||
        (locales !== undefined && typeof locales !== "string")) {
      return new Constructor(locales, adjust(options));
    }
    const cacheKey = locales === undefined ? key : `${key}\0${locales}`;
    let entry = cachedFormatters.get(cacheKey);
    if (!entry || entry.languages !== navigator.languages) {
      if (!entry && cachedFormatters.size >= 32) cachedFormatters.clear();
      entry = {
        languages: navigator.languages,
        formatter: new Constructor(locales, adjust(undefined)),
      };
      cachedFormatters.set(cacheKey, entry);
    }
    return entry.formatter;
  }

  function defineMethods(prototype, methods) {
    for (const name of Object.keys(methods)) {
      Object.defineProperty(prototype, name, {
        value: methods[name],
        writable: true,
        configurable: true,
      });
    }
  }

  // The `= undefined` parameters give each method the length the spec does.
  defineMethods(String.prototype, {
    localeCompare(that, locales = undefined, options = undefined) {
      if (this === undefined || this === null) {
        throw new TypeError(
          "String.prototype.localeCompare called on null or undefined");
      }
      return localeFormatter("collator", intl.Collator, locales, options)
        .compare(String(this), String(that));
    },
  });
  // ECMA-402 TransformCase: only the first requested locale counts, and only
  // its language, and only these languages case differently from the root.
  const CASE_LANGUAGES = new Set(["az", "el", "lt", "tr"]);
  function caseLanguage(locales) {
    const [requested = navigator.languages[0] ?? "und"] =
      requestedLocales(locales);
    const language = requested.split(/[-_]/)[0].toLowerCase();
    return CASE_LANGUAGES.has(language) ? language : null;
  }
  for (const [name, upper] of [
    ["toLocaleUpperCase", true],
    ["toLocaleLowerCase", false],
  ]) {
    defineMethods(String.prototype, {
      [name](locales = undefined) {
        if (this === undefined || this === null) {
          throw new TypeError(
            `String.prototype.${name} called on null or undefined`);
        }
        const text = String(this);
        const language = caseLanguage(locales);
        if (language === null) {
          return upper ? text.toUpperCase() : text.toLowerCase();
        }
        return __MacishTypeHost_intlChangeCase(text, language, upper);
      },
    });
  }
  for (const Type of [Number, BigInt]) {
    defineMethods(Type.prototype, {
      toLocaleString(locales = undefined, options = undefined) {
        const value = Type.prototype.valueOf.call(this);
        return localeFormatter("number", intl.NumberFormat, locales, options)
          .format(value);
      },
    });
  }
  for (const [name, required, defaults] of [
    ["toLocaleString", "any", "all"],
    ["toLocaleDateString", "date", "date"],
    ["toLocaleTimeString", "time", "time"],
  ]) {
    const adjust = (options) => dateTimeOptions(options, required, defaults);
    defineMethods(Date.prototype, {
      [name](locales = undefined, options = undefined) {
        if (Number.isNaN(Date.prototype.getTime.call(this))) {
          return "Invalid Date";
        }
        return localeFormatter(name, intl.DateTimeFormat, locales, options,
          adjust).format(this);
      },
    });
  }
})();
