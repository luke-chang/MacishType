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
})();
