// Host-side glue evaluated before runtime.js. Defines the bridge globals
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

  globalThis.__MacishType_fetch = function (input, resolve, reject) {
    let file;
    try {
      file = __MacishTypeHost_readEngineFile(String(input));
    } catch (error) {
      reject(error);
      return;
    }
    resolve(makeResponse(file.url, file.buffer));
  };

  // Assembles the event object handed to engine hooks. `data` is built by
  // the C++ session per invocation; mutators queue through the
  // __MacishTypeHost_action dispatcher and apply after the hook returns.
  globalThis.__MacishTypeHost_makeEvent = function (data) {
    const event = Object.assign({}, data.fields);
    const states = data.modifierStates || {};
    event.getModifierState = (name) => states[name] === true;

    const cw = data.candidateWindow;
    event.candidateWindow = {
      isVisible: cw.isVisible,
      indexLabels: cw.indexLabels,
      pageSize: cw.pageSize,
      layoutDirection: cw.layoutDirection,
      handleNavigationKeys: cw.handleNavigationKeys,
      handleIndexLabelKeys: cw.handleIndexLabelKeys,
      candidateIndex(char) {
        if (typeof char !== "string" || char.length === 0) return null;
        // A " " label is a blank slot: it reserves the position but is not
        // selectable ("" collapses the labels entirely).
        if (char === " ") return null;
        const index = Array.from(cw.indexLabels).indexOf(char);
        if (index < 0 || index >= cw.pageItemCount) return null;
        return index;
      },
      // Mirrors the host's nav-key table (dispatchCandidateWindowKey) for
      // engines that opt out of handleNavigationKeys.
      navigationIntent(keyEvent) {
        if (!keyEvent || typeof keyEvent !== "object") return null;
        switch (keyEvent.code) {
          case "ArrowUp": return { direction: "up" };
          case "ArrowDown": return { direction: "down" };
          case "ArrowLeft": return { direction: "left" };
          case "ArrowRight": return { direction: "right" };
          case "PageUp": return { direction: "pageUp" };
          case "PageDown": return { direction: "pageDown" };
          case "Home": return { direction: "home" };
          case "End": return { direction: "end" };
          case "Tab":
            return {
              direction: keyEvent.shiftKey ? "itemBackward" : "itemForward",
            };
          default:
            return null;
        }
      },
    };

    const act = globalThis.__MacishTypeHost_action;
    event.updateMarkedText = (text, options) => {
      act("updateMarkedText", text, options);
    };
    event.updateCandidates = (items, options) => {
      act("updateCandidates", items, options);
    };
    event.commit = (candidate) => {
      act("commit", candidate);
    };
    event.commitSelectedCandidate = () => {
      act("commitSelectedCandidate");
    };
    event.commitCandidateAtIndex = (index) => {
      act("commitCandidateAtIndex", index);
    };
    event.navigateCandidates = (direction, options) => {
      act("navigateCandidates", direction, options);
    };
    event.resetContext = () => {
      act("resetContext");
    };
    event.flushStaged = (append) => {
      act("flushStaged", append);
    };
    event.enterAssociatedMode = (heldChar, candidates) => {
      act("enterAssociatedMode", heldChar, candidates);
    };
    return event;
  };

  // Intl.Segmenter. macOS engines get this from JavaScriptCore; quickjs-ng
  // ships no Intl at all, so synthesize the standard API over ICU's UAX #29
  // break iterators (grapheme, word, sentence). The native returns boundary
  // offsets in UTF-16 code units, so `index` matches JavaScriptCore's.
  const intl = globalThis.Intl || (globalThis.Intl = {});

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
    const requested = Array.isArray(locales) ? locales[0] : locales;
    const locale = typeof requested === "string" ? requested : "en";
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

  intl.DateTimeFormat = function DateTimeFormat(locales, options) {
    // Callable with or without `new`, per ECMA-402.
    const self =
      this instanceof intl.DateTimeFormat
        ? this
        : Object.create(intl.DateTimeFormat.prototype);
    const o = options ? Object(options) : {};

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
    // Default when nothing is requested: numeric year, month, and day.
    if (!dateStyle && !timeStyle && !hasComponent) {
      comp.year = "numeric";
      comp.month = "numeric";
      comp.day = "numeric";
    }
    const skeleton = dateStyle || timeStyle ? "" : dtfSkeleton(comp);

    const requested = Array.isArray(locales) ? locales[0] : locales;
    let localeTag = typeof requested === "string" ? requested : "en";
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
})();
