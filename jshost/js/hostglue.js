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
    const granularity = (options && options.granularity) || "grapheme";
    if (
      granularity !== "grapheme" &&
      granularity !== "word" &&
      granularity !== "sentence"
    ) {
      throw new RangeError(
        "Value " +
          granularity +
          " out of range for Intl.Segmenter options property granularity",
      );
    }
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

  function dtfEnum(name, value, allowed) {
    if (value === undefined) return undefined;
    const s = String(value);
    if (allowed.indexOf(s) === -1) {
      throw new RangeError(
        "Value " +
          s +
          " out of range for Intl.DateTimeFormat options property " +
          name,
      );
    }
    return s;
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

  // ECMA-402 ToDateTimeOptions: the fields a formatter shows when the caller
  // names none of the kind it requires. Defaults are defined rather than
  // assigned, so a read-only field inherited from the caller's object is no
  // obstacle.
  const DATE_FIELDS = ["weekday", "year", "month", "day"];
  const TIME_FIELDS = ["dayPeriod", "hour", "minute", "second",
    "fractionalSecondDigits"];
  function dateTimeOptions(options, required, defaults) {
    const adjusted = Object.create(optionsObject(options));
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
      for (const field of fields) {
        Object.defineProperty(adjusted, field, {
          value: "numeric",
          writable: true,
          enumerable: true,
          configurable: true,
        });
      }
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

    const weekday = dtfEnum("weekday", o.weekday, ["narrow", "short", "long"]);
    const era = dtfEnum("era", o.era, ["narrow", "short", "long"]);
    const year = dtfEnum("year", o.year, ["numeric", "2-digit"]);
    const month = dtfEnum("month", o.month, [
      "numeric",
      "2-digit",
      "narrow",
      "short",
      "long",
    ]);
    const day = dtfEnum("day", o.day, ["numeric", "2-digit"]);
    const hour = dtfEnum("hour", o.hour, ["numeric", "2-digit"]);
    const minute = dtfEnum("minute", o.minute, ["numeric", "2-digit"]);
    const second = dtfEnum("second", o.second, ["numeric", "2-digit"]);
    const dayPeriod = dtfEnum("dayPeriod", o.dayPeriod, ["narrow", "short", "long"]);
    const timeZoneName = dtfEnum("timeZoneName", o.timeZoneName, Object.keys(DTF_TZNAME));
    const hourCycle = dtfEnum("hourCycle", o.hourCycle, ["h11", "h12", "h23", "h24"]);
    const dateStyle = dtfEnum("dateStyle", o.dateStyle, Object.keys(DTF_STYLE));
    const timeStyle = dtfEnum("timeStyle", o.timeStyle, Object.keys(DTF_STYLE));
    let fractionalSecondDigits;
    if (o.fractionalSecondDigits !== undefined) {
      const n = Math.floor(Number(o.fractionalSecondDigits));
      if (!(n >= 1 && n <= 3)) {
        throw new RangeError(
          "fractionalSecondDigits value is out of range for Intl.DateTimeFormat",
        );
      }
      fractionalSecondDigits = n;
    }
    const hour12 = o.hour12 === undefined ? undefined : !!o.hour12;

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

    let localeTag = resolveLocale(locales);
    // Fold calendar/numberingSystem into the tag as -u- extensions; ICU maps
    // them to locale keywords.
    const ext = [];
    if (o.calendar) ext.push("ca", String(o.calendar));
    if (o.numberingSystem) ext.push("nu", String(o.numberingSystem));
    if (ext.length) {
      localeTag += (/-u-/.test(localeTag) ? "-" : "-u-") + ext.join("-");
    }

    const resolved = __MacishTypeHost_intlDateTimeResolve(
      localeTag,
      skeleton,
      o.timeZone ? String(o.timeZone) : "",
      dateStyle ? DTF_STYLE[dateStyle] : -1,
      timeStyle ? DTF_STYLE[timeStyle] : -1,
    );
    if (!resolved.ok) {
      if (resolved.error === "invalid-timezone") {
        throw new RangeError("Invalid time zone specified: " + o.timeZone);
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
        locale: resolved.locale,
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

  function nfClampInt(value, lo, hi, fallback) {
    if (value === undefined) return fallback;
    let n = Math.floor(Number(value));
    if (isNaN(n)) return fallback;
    if (n < lo) n = lo;
    if (n > hi) n = hi;
    return n;
  }

  function nfNumberString(value) {
    if (typeof value === "bigint") return value.toString();
    if (typeof value === "string") return value.trim();
    return String(Number(value));
  }

  function nfSkeleton(o) {
    const tokens = [];
    if (o.style === "percent") {
      tokens.push("percent", "scale/100");
    } else if (o.style === "currency") {
      if (!o.currency || !/^[A-Za-z]{3}$/.test(String(o.currency))) {
        throw new RangeError("Invalid currency code: " + o.currency);
      }
      tokens.push("currency/" + String(o.currency).toUpperCase());
      const width = {
        code: "unit-width-iso-code",
        name: "unit-width-full-name",
        narrowSymbol: "unit-width-narrow",
      }[o.currencyDisplay];
      if (width) tokens.push(width);
    } else if (o.style === "unit") {
      if (!o.unit) throw new TypeError("unit style requires a unit");
      tokens.push("unit/" + String(o.unit));
      const width = { long: "unit-width-full-name", narrow: "unit-width-narrow" }[
        o.unitDisplay
      ];
      if (width) tokens.push(width);
    }

    if (o.notation === "scientific") tokens.push("scientific");
    else if (o.notation === "engineering") tokens.push("engineering");
    else if (o.notation === "compact")
      tokens.push(o.compactDisplay === "long" ? "compact-long" : "compact-short");

    if (
      o.minimumSignificantDigits !== undefined ||
      o.maximumSignificantDigits !== undefined
    ) {
      const min = nfClampInt(o.minimumSignificantDigits, 1, 21, 1);
      const max = nfClampInt(o.maximumSignificantDigits, min, 21, 21);
      tokens.push("@".repeat(min) + "#".repeat(Math.max(0, max - min)));
    } else {
      const isCurrency = o.style === "currency";
      const defMin = isCurrency ? 2 : 0;
      const defMax = isCurrency ? 2 : o.style === "percent" ? 0 : 3;
      const min = nfClampInt(o.minimumFractionDigits, 0, 100, defMin);
      const max = nfClampInt(o.maximumFractionDigits, min, 100, Math.max(min, defMax));
      if (max === 0) tokens.push("precision-integer");
      else tokens.push("." + "0".repeat(min) + "#".repeat(Math.max(0, max - min)));
    }

    if (o.minimumIntegerDigits !== undefined) {
      tokens.push("integer-width/+" + "0".repeat(nfClampInt(o.minimumIntegerDigits, 1, 21, 1)));
    }

    if (o.useGrouping === false || o.useGrouping === "false")
      tokens.push("group-off");
    else if (o.useGrouping === "always" || o.useGrouping === true)
      tokens.push("group-on-aligned");

    const sign = {
      always: "sign-always",
      never: "sign-never",
      exceptZero: "sign-except-zero",
      negative: "sign-negative",
    }[o.signDisplay];
    if (sign) tokens.push(sign);

    if (o.roundingMode && NF_ROUNDING[o.roundingMode])
      tokens.push(NF_ROUNDING[o.roundingMode]);

    return tokens.join(" ");
  }

  intl.NumberFormat = function NumberFormat(locales, options) {
    const self =
      this instanceof intl.NumberFormat
        ? this
        : Object.create(intl.NumberFormat.prototype);
    const o = optionsObject(options);
    const style = o.style ? String(o.style) : "decimal";
    if (["decimal", "currency", "percent", "unit"].indexOf(style) === -1) {
      throw new RangeError(
        "Value " + style + " out of range for Intl.NumberFormat options property style",
      );
    }
    const skeleton = nfSkeleton(Object.assign({}, o, { style }));

    let localeTag = resolveLocale(locales);
    if (o.numberingSystem) {
      localeTag +=
        (/-u-/.test(localeTag) ? "-" : "-u-") + "nu-" + String(o.numberingSystem);
    }
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
        locale: resolved.locale,
        numberingSystem: resolved.numberingSystem,
        style,
      };
      if (style === "currency") {
        r.currency = String(o.currency).toUpperCase();
        r.currencyDisplay = o.currencyDisplay || "symbol";
      }
      if (style === "unit") {
        r.unit = String(o.unit);
        r.unitDisplay = o.unitDisplay || "short";
      }
      if (o.notation) r.notation = String(o.notation);
      if (o.signDisplay) r.signDisplay = String(o.signDisplay);
      r.useGrouping = o.useGrouping === undefined ? "auto" : o.useGrouping;
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
    const type = o.type ? String(o.type) : "cardinal";
    if (type !== "cardinal" && type !== "ordinal") {
      throw new RangeError(
        "Value " + type + " out of range for Intl.PluralRules options property type",
      );
    }
    const typeCode = type === "ordinal" ? 1 : 0;
    const skeleton = nfSkeleton({
      style: "decimal",
      minimumIntegerDigits: o.minimumIntegerDigits,
      minimumFractionDigits: o.minimumFractionDigits,
      maximumFractionDigits: o.maximumFractionDigits,
      minimumSignificantDigits: o.minimumSignificantDigits,
      maximumSignificantDigits: o.maximumSignificantDigits,
      roundingMode: o.roundingMode,
    });

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
  intl.Collator = function Collator(locales, options) {
    const self =
      this instanceof intl.Collator
        ? this
        : Object.create(intl.Collator.prototype);
    const o = optionsObject(options);

    const usage = o.usage ? String(o.usage) : "sort";
    if (usage !== "sort" && usage !== "search") {
      throw new RangeError(
        "Value " + usage + " out of range for Intl.Collator options property usage",
      );
    }
    const sensitivity = o.sensitivity ? String(o.sensitivity) : "variant";
    if (["base", "accent", "case", "variant"].indexOf(sensitivity) === -1) {
      throw new RangeError(
        "Value " +
          sensitivity +
          " out of range for Intl.Collator options property sensitivity",
      );
    }
    const caseFirst = o.caseFirst ? String(o.caseFirst) : "false";
    if (["upper", "lower", "false"].indexOf(caseFirst) === -1) {
      throw new RangeError(
        "Value " +
          caseFirst +
          " out of range for Intl.Collator options property caseFirst",
      );
    }
    const numeric = !!o.numeric;
    const ignorePunctuation = !!o.ignorePunctuation;

    // sensitivity → (strength, case level).
    let strength = 2; // variant -> tertiary
    let caseLevel = 0;
    if (sensitivity === "base") strength = 0;
    else if (sensitivity === "accent") strength = 1;
    else if (sensitivity === "case") {
      strength = 0;
      caseLevel = 1;
    }
    const cf = caseFirst === "upper" ? 1 : caseFirst === "lower" ? 2 : 0;
    const signature = [
      strength,
      caseLevel,
      numeric ? 1 : 0,
      cf,
      ignorePunctuation ? 1 : 0,
    ].join(",");

    let localeTag = resolveLocale(locales);
    if (o.collation) {
      localeTag +=
        (/-u-/.test(localeTag) ? "-" : "-u-") + "co-" + String(o.collation);
    }
    const resolved = __MacishTypeHost_intlResolveLocale(localeTag);

    self.compare = (a, b) =>
      __MacishTypeHost_intlCollatorCompare(localeTag, signature, String(a), String(b));
    self.resolvedOptions = () => ({
      locale: resolved.locale,
      usage,
      sensitivity,
      numeric,
      caseFirst,
      ignorePunctuation,
      collation: o.collation ? String(o.collation) : "default",
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
