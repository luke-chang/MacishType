// Type definitions for JavaScript engines loaded by MacishType.
//
// MacishType hosts bridge to user-supplied engines through an embedded
// JavaScript runtime (JavaScriptCore on macOS, QuickJS on fcitx5). The
// engine module's default export is duck-typed: the host calls each
// method only if defined, so every member of `InputEngine` is optional.
//
// Usage:
//   // In TypeScript
//   import type { InputEngine, KeyEvent } from "../utils/MacishType";
//
//   // In plain JS with JSDoc
//   /** @typedef {import("../utils/MacishType").InputEngine} InputEngine */
//   /** @implements {InputEngine} */
//   export default class MyEngine { ... }

export type LayoutDirection = "horizontal" | "vertical";

export type NavigationDirection =
  | "up"
  | "down"
  | "left"
  | "right"
  | "home"
  | "end"
  | "pageUp"
  | "pageDown"
  | "pageForward"
  | "pageBackward"
  | "itemForward"
  | "itemBackward";

/**
 * Snapshot of the candidate window at the moment `handleKey` fires.
 * All values are read-only — mutations go through `updateCandidates`.
 */
export interface CandidateWindowState {
  /** Whether the candidate window is currently shown on screen. */
  readonly isVisible: boolean;
  /** Characters used as on-screen index labels, e.g. "1234567890". */
  readonly indexLabels: string;
  /** Number of candidates displayed per page. */
  readonly pageSize: number;
  /** Whether candidates are arranged horizontally or vertically. */
  readonly layoutDirection: LayoutDirection;
  /**
   * When true, the host handles standard nav keys (arrows / Tab / Page /
   * Home / End) and Enter while the window is visible — `handleKey` /
   * `handleAssociatedKey` never see them. When false, the engine handles
   * them. One case stays with the engine either way: in associated mode
   * with nothing highlighted, Enter has no candidate to commit, so it
   * dismisses like any other unhandled key.
   */
  readonly handleNavigationKeys: boolean;
  /**
   * When true, the host handles `indexLabels` keys while the window is
   * visible — `handleKey` / `handleAssociatedKey` never see them.
   * When false, the engine handles them.
   */
  readonly handleIndexLabelKeys: boolean;
  /**
   * When true (an associated-mode window under the Shift + number keys
   * policy), each digit label is selected with Shift + the physical key
   * that names it — main row `Digit1`…`Digit0` or keypad
   * `Numpad1`…`Numpad0` — independent of keyboard layout. Non-digit
   * labels keep plain character matching.
   */
  readonly indexLabelDigitsRequireShift: boolean;
  /**
   * Maps a keystroke to its page-relative 0-based candidate position,
   * or null when it selects nothing. Pair with `commitCandidateAtIndex`
   * to commit by index label. Passing the key event applies the host's
   * full rule — Option-modified keys never select, and digit labels
   * require Shift + a physical digit key under
   * `indexLabelDigitsRequireShift`; a bare character matches by produced
   * character, so digit labels never match through the string form while
   * the requirement is on.
   */
  candidateIndex(event: KeyEvent | string): number | null;
  /**
   * Standard nav-key lookup: returns the `direction` / `options` pair
   * to pass straight to `navigateCandidates`, or null if the event
   * isn't a nav key. Same mapping the host uses internally — for
   * engines that opt out of `handleNavigationKeys` and want to emit
   * the action themselves without reimplementing the keyCode table.
   *
   * @example
   *   const intent = event.candidateWindow.navigationIntent(event);
   *   if (intent) event.navigateCandidates(intent.direction, intent.options);
   */
  navigationIntent(event: KeyEvent): {
    direction: NavigationDirection;
    options?: NavigationOptions;
  } | null;
}

/** Candidate emitted by the engine. */
export interface Candidate {
  /** Display text shown in the candidate window. */
  candidate: string;
  /** Optional disambiguator shown beside the candidate (e.g. a text description of a symbol). */
  annotation?: string;
  /**
   * Opaque value that round-trips back to the engine via `candidateConfirmed`
   * and `candidateSelectionChanged`, letting engines attach IDs or metadata
   * without parsing display text.
   */
  payload?: unknown;
}

/** `updateCandidates` and `commit` accept either a plain string or a Candidate. */
export type CandidateInput = string | Candidate;

/**
 * Character-index range. Indices count characters (extended grapheme
 * clusters), NOT UTF-16 code units. Plain `str.length` / `str[i]` is
 * UTF-16-indexed and mis-aligns on surrogate pairs and ZWJ sequences;
 * use `Intl.Segmenter` with `granularity: "grapheme"` to align with
 * the host's character count.
 *
 * @example
 *   const seg = new Intl.Segmenter(undefined, { granularity: "grapheme" });
 *   const characterCount = [...seg.segment(markedText)].length;
 */
export interface EmphasisRange {
  /** Index where the range begins (inclusive). */
  start: number;
  /** Index where the range ends (exclusive). */
  end: number;
}

/** Options for `updateMarkedText`. */
export interface MarkedTextOptions {
  /**
   * Caret position within the text. Omitted means "default to end-of-text".
   * `0` is distinct from omission — it explicitly places the caret at the
   * start.
   */
  cursor?: number;
  /**
   * Number of leading characters that should be committed when the
   * composition ends. Negative values stage the whole text.
   */
  staged?: number;
  /** Sub-range of the text to render with emphasis (e.g. thicker underline). */
  emphasis?: EmphasisRange;
}

/** Options for `updateCandidates`. */
export interface CandidateUpdateOptions {
  /**
   * Cursor position in `markedText` where the candidate window's left
   * edge anchors. Range `0...markedText.length` — `0` = before the
   * first character, `length` = after the last. Grapheme clusters,
   * not UTF-16. Resolved against the marked text as the host applies
   * this update; rewrites that land later leave the anchor in place.
   * Currently only supported by the macOS host — under fcitx5, window
   * placement is frontend-driven.
   */
  anchorAt?: number;
  /**
   * Initial selection. 0 (default) highlights the first candidate.
   * Positive values highlight that absolute index (clamped to the
   * displayed range). -1 suspends the initial highlight; the first
   * navigation reveals the highlight and resumes normal behavior.
   */
  initialHighlight?: number;
  /** Override the candidate window's layout direction for this update only. */
  layoutDirection?: LayoutDirection;
  /** Override the index-label characters for this update only. */
  indexLabels?: string;
  /** Override the per-page candidate count for this update only. */
  pageSize?: number;
  /** Override host nav-key handling for this update only. */
  handleNavigationKeys?: boolean;
  /** Override host index-label key handling for this update only. */
  handleIndexLabelKeys?: boolean;
  /**
   * Override the digit-label Shift requirement for this update only —
   * same matching the host's associated-mode windows use.
   */
  indexLabelDigitsRequireShift?: boolean;
}

/** Options for `navigateCandidates`. */
export interface NavigationOptions {
  /** Wrap around when navigating past the first/last candidate. */
  wrapping?: boolean;
}

/**
 * Mutator surface attached to every event object. Calls queue actions
 * that the host applies only after the engine method returns; reading
 * `event.markedText` or other context fields after a mutator call still
 * returns the snapshot from method entry, not the queued value.
 */
export interface EventMutators {
  /** Replace the composing (marked) text shown in the active text field. */
  updateMarkedText(text: string, options?: MarkedTextOptions): void;
  /**
   * Replace the candidate list shown in the candidate window. Pass an
   * empty array to hide the window. Declare candidates alongside a
   * non-empty `markedText`: on macOS the window anchors to the
   * composition, and some clients deliver keys to the input method only
   * while a composition is active.
   */
  updateCandidates(items: readonly CandidateInput[], options?: CandidateUpdateOptions): void;
  /** Engine-driven commit. Triggers `candidateConfirmed` if defined. */
  commit(candidate: CandidateInput): void;
  /**
   * Commit whichever candidate is currently highlighted. With the window
   * visible but nothing highlighted, reports an empty commit
   * (`candidateConfirmed` fires with `candidate` `""`, `absoluteIndex` -1)
   * for the engine to interpret; with the window not visible it is a no-op
   * (pre-check via `candidateWindow.isVisible`).
   */
  commitSelectedCandidate(): void;
  /**
   * Commit the candidate at the given page-relative index (0-based, within
   * the current `pageSize`). Pair with `candidateWindow.candidateIndex(event)`
   * to commit by index label.
   */
  commitCandidateAtIndex(index: number): void;
  /** Move the candidate-window selection in the given direction. */
  navigateCandidates(direction: NavigationDirection, options?: NavigationOptions): void;
  /** Clear marked text, candidates, staged text, and associated-mode state. */
  resetContext(): void;
  /**
   * Commit the staged prefix and optionally append more text. Use with no
   * argument to flush whatever was staged via `updateMarkedText({ staged })`.
   */
  flushStaged(append?: string): void;
  /**
   * Enter associated mode: `heldChar` (which may be more than one
   * character) becomes staged marked text, replacing any previously staged
   * text — fold `event.stagedText` in to carry it forward. `candidates`
   * appear as suggested follow-ups. Picking a candidate commits `heldChar`
   * followed by the chosen candidate; typing anything else commits
   * `heldChar` alone and the new key is processed normally.
   *
   * Omitting `candidates` falls back to the host's `AssociatedDictionary`
   * dictionary keyed by `heldChar`'s last character. That fallback needs the
   * manifest to opt in via a
   * `{ "key": "enableAssociatedMode", "type": "system" }` field with the
   * toggle on.
   *
   * Whenever the resolved list comes out empty — an explicit `[]`, a
   * dictionary miss, or the opt-in absent — the host commits `heldChar` and
   * ends the composition. Chained engines lean on this to finish a chain.
   */
  enterAssociatedMode(heldChar: string, candidates?: readonly string[]): void;
}

/** Context fields shared by every event payload. */
export interface EventContext {
  readonly markedText: string;
  readonly stagedText: string;
  readonly isComposing: boolean;
  readonly isAssociating: boolean;
  /** Snapshot of the candidate window state at method entry. */
  readonly candidateWindow: CandidateWindowState;
}

/**
 * Payload passed to `handleKey`. Field names and semantics track web
 * `KeyboardEvent` (https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent)
 * so existing web-keyboard handling code drops in with minimal rewrites.
 *
 * The host omits `Event` base properties (`type`, `timeStamp`, `target`,
 * `bubbles`, etc.) — KeyEvent is a method parameter, not a dispatched
 * event, so propagation / cancellation machinery doesn't apply. Cancellation
 * is expressed by `handleKey`'s return value, not `preventDefault()`.
 */
export interface KeyEvent extends EventContext, EventMutators {
  /**
   * Layout-aware key value, e.g. `"a"` / `"A"` / `"!"` for character keys
   * (reflecting Shift + Caps Lock + the active keyboard layout), or a named
   * value for non-printable keys (`"Enter"` / `"Tab"` / `"Escape"` /
   * `"ArrowLeft"` / `"Backspace"` / `" "` for Space, etc.). Falls back to
   * `"Unidentified"` for unknown keys with no character output.
   *
   * Use `key` when you want the *character the user actually typed*. Use
   * `code` when you want the *physical key position*.
   */
  readonly key: string;
  /**
   * Layout-independent physical key code. Always reflects the US QWERTY
   * position of the pressed key, so `"KeyA"` means "the key in QWERTY-A's
   * position" regardless of whether the active layout is Dvorak / AZERTY
   * etc. — on AZERTY the same key produces `key: "q"` but
   * `code: "KeyA"` (still the physical A spot). Returns `""` for unknown
   * physical keys.
   *
   * Numpad keys use dedicated `"Numpad*"` codes (e.g. `"Numpad0"` /
   * `"NumpadEnter"` / `"NumpadAdd"`), never `"Digit*"` plus `location`.
   * Mac's physical Clear key on the numpad reports `code: "NumLock"` per
   * the W3C UI Events spec — Clear sits where NumLock lives on PC keyboards.
   *
   * Recommended handling ("Numeric keypad keys" in the README): keypad
   * character keys (`"Numpad*"` except `"NumpadEnter"`) never enter the
   * composition — swallow while composing, pass through when idle.
   * NumpadEnter behaves like Return (match `key === "Enter"`, which covers
   * both); Clear behaves like Escape while composing (match
   * `key === "Clear"` — its code is `"NumLock"`).
   *
   * Format examples: `"KeyA"` / `"Digit1"` / `"Space"` / `"Enter"` /
   * `"ArrowLeft"` / `"ShiftLeft"` / `"Numpad0"` / `"F1"`.
   */
  readonly code: string;
  /** True when Option is held. (macOS Option maps to web Alt.) */
  readonly altKey: boolean;
  /** True when Control is held. */
  readonly ctrlKey: boolean;
  /** True when Shift is held. */
  readonly shiftKey: boolean;
  /** True when Command is held. (macOS Command maps to web Meta.) */
  readonly metaKey: boolean;
  /**
   * True when this keydown was synthesized by the OS as a result of the user
   * holding the key down past the repeat delay. The first keydown of a press
   * is always `false`; subsequent repeats are `true`.
   */
  readonly repeat: boolean;
  /**
   * Where on the keyboard the key sits:
   * - `0` — standard (default; main keyboard area)
   * - `1` — left side of a paired modifier (left Shift / Control / Option / Command)
   * - `2` — right side of a paired modifier
   * - `3` — numpad cluster
   *
   * For numpad keys this is redundant with `code` (since `code` already
   * starts with `"Numpad"`); prefer `code` for numpad detection.
   */
  readonly location: number;
  /**
   * Query an individual modifier or lock state.
   *
   * Live states: `"Shift"` / `"Control"` / `"Alt"` / `"Meta"` (same as the
   * boolean `*Key` properties above), `"CapsLock"`, and `"NumLock"` — that
   * last one host-dependent, as in browsers: `false` on macOS, live on
   * fcitx5 only where the frontend forwards Mod2.
   *
   * Every other web-spec string returns `false` on both hosts. A key can
   * still arrive while its state reads `false`, so detect those with `code`.
   * See README for the per-host details.
   */
  getModifierState(key: string): boolean;
  /**
   * Host extension (not part of the web KeyboardEvent spec). The layout-aware
   * character with Option / Command / Control stripped; Shift is preserved.
   *
   * Useful on macOS where Option doubles as a dead-key modifier and rewrites
   * `key` (Option+a → `"å"` on US, `"π"` on Dvorak via the layout's Option
   * layer). `keyIgnoringModifiers` gives the original character the active
   * layout would have produced without those modifiers, so it works across
   * Dvorak / AZERTY / etc.:
   *
   * - Option+A on US → `"a"`; Option+(Dvorak p position) → `"p"`
   * - Shift+1 → `"!"` (Shift is preserved)
   * - Tab → `"\t"`, Escape → `"\u{1B}"`, Backspace → `"\u{7F}"` (control
   *   characters for named keys — prefer `code` for those)
   */
  readonly keyIgnoringModifiers: string;
}

/** Payload passed to `candidateConfirmed` and `candidateSelectionChanged`. */
export interface ConfirmEvent extends EventContext, EventMutators {
  /**
   * Confirmed display text. `""` on an empty commit
   * (`commitSelectedCandidate` with nothing highlighted).
   */
  readonly candidate: string;
  /**
   * Absolute index of the candidate within the list emitted by the most
   * recent `updateCandidates`. -1 when no candidate is active (e.g. a
   * commit fired while `initialHighlight: -1` was in effect, or an
   * engine-driven `commit()`).
   *
   * Distinct from the page-relative index taken by `commitCandidateAtIndex(_)`.
   * Example with `pageSize: 5`, user on page 1 confirms the 2nd visible item:
   *   `commitCandidateAtIndex(1)` — page-relative (0..pageSize-1)
   *   `event.absoluteIndex === 6` — into the full list
   */
  readonly absoluteIndex: number;
  /** Annotation propagated from the original Candidate emitted via `updateCandidates`. */
  readonly annotation?: string;
  /** Payload propagated from the original Candidate emitted via `updateCandidates`. */
  readonly payload?: unknown;
}

/**
 * Contract for an engine module's default export. Every method is optional;
 * the host calls only those that exist on the instance. The class is
 * instantiated once per text-field session, so per-field state can live
 * on `this`.
 */
export interface InputEngine {
  /** Per-session setup. Fires when the user focuses a text field. */
  activate?(): void;
  /** Per-session teardown. Fires when focus leaves the text field. */
  deactivate?(): void;
  /**
   * Fires when the host ends composition — in-app commit (mouse click
   * elsewhere, Cmd+A) or session deactivate (app switch, focus loss). Clear
   * any composing state held on `this` here. The deactivate path can fire it
   * with nothing composing (e.g. switching apps), so keep it idempotent.
   */
  compositionEnded?(): void;
  /**
   * Called for every keystroke.
   *
   * Return `true` to mark the key consumed. Returning `false` / `undefined`
   * (including omitting the method) lets the host pass the key through to
   * the OS. Queued event mutators apply regardless of the return value.
   */
  handleKey?(event: KeyEvent): boolean | void;
  /**
   * Called in associated mode for keys that the candidate window didn't
   * handle (keys outside its scope, in-scope keys when
   * `handleNavigationKeys` / `handleIndexLabelKeys` is off, and Enter
   * while nothing is highlighted).
   *
   * Return `true` to mark the key consumed; queued mutators apply.
   * Returning `false` / `undefined` (including omitting the method) makes
   * the host dismiss associated mode (flush staged) and then process the
   * key fresh via `handleKey`.
   *
   * Omitting the method falls back to host default (Escape dismisses,
   * everything else triggers fall-through). Engines that define this
   * method to override behavior should typically still handle Escape
   * — JavaScript lacks `super`, so there's no automatic fallback to
   * the host default.
   */
  handleAssociatedKey?(event: KeyEvent): boolean | void;
  /**
   * Called after a candidate is committed (engine-driven or by the user),
   * or on an empty commit (`candidate` `""`, `absoluteIndex` -1) from
   * `commitSelectedCandidate` with nothing highlighted.
   *
   * Return `true` to mark as handled. Returning `false` / `undefined`
   * (including omitting the method) makes the host fall back to its
   * default behavior; queued mutators still apply and the fallback layers
   * on top — see README.
   */
  candidateConfirmed?(event: ConfirmEvent): boolean | void;
  /**
   * Called when the highlighted candidate changes (e.g. after
   * navigation), including as a candidate update applies its
   * `initialHighlight`.
   *
   * Return `true` to mark as handled. Returning `false` / `undefined`
   * (including omitting the method) makes the host fall back to its
   * default behavior (currently a no-op); queued mutators still apply
   * — see README.
   */
  candidateSelectionChanged?(event: ConfirmEvent): boolean | void;
}

/**
 * One reverse-lookup result: an input code that produces the queried
 * character, plus an optional short label the host renders dimmed next to
 * the code. Plain strings are accepted wherever a ReverseCode is expected.
 */
export interface ReverseCode {
  code: string;
  annotation?: string;
}

/**
 * Static-side contract for the default-export class, declared separately
 * because `InputEngine` describes instances — the host reads these members
 * off the class itself.
 */
export interface InputEngineConstructor {
  new (): InputEngine;
  /**
   * All input codes that produce `character` in this engine. Called only
   * when the manifest declares `capabilities.reverseLookup: true`.
   *
   * `character` is a single user-perceived character (grapheme cluster);
   * its `.length` can exceed 1 (surrogate pairs, combining marks), so
   * don't assume `length === 1`. Return `[]` when it has no codes.
   */
  reverseLookup?(character: string): (string | ReverseCode)[];
  /**
   * Optional. Awaited by the host before reverse lookups — resolve when the
   * lookup data is ready (await the table fetch, build the reverse index
   * here). Idempotency should come from null-checking the built index, not
   * from caching this promise. A rejected promise — or a synchronous throw
   * — marks the engine as failed for this lookup session. Must eventually
   * settle. Absent = ready right after module load.
   */
  prepareReverseLookup?(): void | Promise<void>;
  /**
   * Optional. Release lookup-only state built by `prepareReverseLookup`.
   * May arrive while a prepare promise is still pending — a late prepare
   * may rebuild the index afterward (held until the next end or module
   * unload; the host discards the abandoned query's results). Engines whose
   * reverse data is shared with the typing path must NOT declare this.
   */
  endReverseLookup?(): void;
}

/** Any value representable as JSON. */
export type JSONValue =
  | string | number | boolean | null
  | JSONValue[]
  | { [key: string]: JSONValue };

/** Snapshot of user-edited settings, keyed by manifest field `key`. */
export type Settings = { readonly [key: string]: JSONValue };

export interface SettingsChangeEvent {
  readonly type: "settingschange";
}

/**
 * Fired on `globalThis` when the user flips a menu item from the host's
 * IME menu. Read `manifest.menu` for the new values. The engine's own
 * writes do NOT fire it — engines never hear their own echo.
 */
export interface MenuChangeEvent {
  readonly type: "menuchange";
}

/**
 * Fired on `globalThis` when a capability toggle changes from the host
 * side (the user flipping its IME-menu entry). Read `manifest.toggle`
 * for the new value. The engine's own writes do NOT fire it — engines
 * never hear their own echo.
 */
export interface ToggleChangeEvent {
  readonly type: "togglechange";
  /** The toggle that changed, e.g. `"outputToSimplified"`. */
  readonly key: string;
}

/**
 * Live values of the manifest-declared `menu` items, keyed by item
 * `key` (dividers carry no value). Engine-global: persisted host-side
 * and shared with the IME menu's checkmarks.
 *
 * Unlike `manifest.candidateWindow`, writes act immediately — the very
 * next commit reflects them. Undeclared keys read `undefined`; writes
 * to them are logged via OSLog and ignored.
 */
export interface Menu {
  [key: string]: boolean | undefined;
}

/**
 * Live values of the host's capability-backed toggles. The key set is
 * derived from the manifest `capabilities` declarations and the host's
 * availability rules, not from a manifest.json key. Every property is
 * optional — a declared capability does not by itself guarantee the
 * toggle exists on a given host.
 *
 * Writes act immediately and persist host-side, shared with the IME
 * menu's checkmark. Unavailable keys read `undefined`; writes to them
 * are logged via OSLog and ignored.
 */
export interface Toggle {
  /** Traditional→Simplified commit transform. */
  outputToSimplified?: boolean;
}

/**
 * Live candidate-window configuration. Reads return engine writes (if
 * any), else manifest declarations, else `undefined`. Writes take effect
 * at the next session activate.
 *
 * Invalid writes — wrong type, out of range, unknown field — are logged
 * via OSLog and silently ignored; engine execution continues.
 *
 * Not the same as `event.candidateWindow` (per-event snapshot of the
 * effective state).
 */
export interface CandidateWindow {
  layoutDirection?: LayoutDirection;
  fontSize?: number;
  indexLabels?: string;
  pageSize?: number;
  widerExpandedColumns?: boolean;
  moveOnExpand?: boolean;
  horizontalMaxVisibleRows?: number;
  verticalMinVisibleRows?: number;
  expandable?: boolean;
  /**
   * Host policy: when true (default), standard nav keys (arrows / Tab /
   * Page / Home / End) and Enter are intercepted by the host while the
   * candidate window is visible. Set to false to route them to the
   * engine (`handleKey` in normal mode, `handleAssociatedKey` in
   * associated mode).
   */
  handleNavigationKeys?: boolean;
  /**
   * Host policy: when true (default), `indexLabels` keys are
   * intercepted by the host while the candidate window is visible.
   * Set to false to route them to the engine (`handleKey` in normal
   * mode, `handleAssociatedKey` in associated mode).
   */
  handleIndexLabelKeys?: boolean;
  /**
   * When true, each digit label is selected with Shift + the physical
   * key that names it — main row or keypad; non-digit labels keep plain
   * character matching. How the requirement is presented to the user is
   * host-specific. The same field the host's associated-mode policy
   * sets on its own windows.
   */
  indexLabelDigitsRequireShift?: boolean;
  /**
   * The engine's preference for the associated-mode window's selection
   * keys, honored unless the user forces number keys or Shift + number
   * keys in the host's settings.
   * `numbers` (the default) / `shiftNumbers` request digit selection;
   * `inherit` keeps the engine's own `indexLabels` / `pageSize`.
   *
   * A declaration, not a window field: the host expands it into
   * `indexLabels`, `pageSize`, and `indexLabelDigitsRequireShift` when
   * an associated-mode window opens. It lives only here — the per-event
   * snapshot carries the expanded fields instead.
   */
  associatedModeIndexLabels?: "numbers" | "shiftNumbers" | "inherit";
}

/** A frozen, read-only host-provided table. `query(key)` returns the value
 *  mapped to `key`. */
export interface LookupModule<V> {
  query(key: string): V;
}

/**
 * Host-provided data tables enabled via manifest.json `modules`. A module
 * enabled there is always present here — a table with no data for the engine's
 * resolved language is an empty view (every query returns the miss value),
 * never a missing property, so reads need no guarding. Reading a module you
 * didn't enable is `undefined` at runtime.
 */
export interface Modules {
  /** Whether a value is renderable by an installed font, e.g. "的" → true. Absent → false.
   *  Live: query reflects current coverage and updates when fonts change (see
   *  `fontcoveragechange`). */
  readonly fontCoverage: LookupModule<boolean>;
  /** Symbol → human-readable name, e.g. "！" → "驚嘆號". Absent → undefined. */
  readonly symbolNames: LookupModule<string | undefined>;
  /** Character → frequency count, e.g. "的" → 615175; higher is more common. Absent → 0. */
  readonly wordFrequency: LookupModule<number>;
}

/**
 * Engine-wide info injected by the host.
 */
export interface Manifest {
  /**
   * Engine display name from manifest.json `name`, resolved for the active
   * locale. `undefined` only when the manifest omits `name`; a present-but-
   * empty value resolves to `""`. The Settings window title appends it to the
   * host's slot label (e.g. "JS" becomes "JS (<name>)"), skipping the parens
   * when the value is blank.
   */
  readonly name?: string;

  /**
   * Candidate-window override cache. See `CandidateWindow` for details.
   */
  readonly candidateWindow: CandidateWindow;

  /**
   * Host-provided data tables enabled via manifest.json `modules`.
   * See `Modules`.
   */
  readonly modules: Modules;

  /**
   * User settings keyed by manifest field `key`. Deeply read-only —
   * writes throw `TypeError`. The reference is stable across updates;
   * `const { settings } = manifest` is safe and reads always see the
   * latest values.
   */
  readonly settings: Settings;

  /**
   * Live menu-item values, read/write. See `Menu` for details.
   */
  readonly menu: Menu;

  /**
   * Live capability-toggle values, read/write. See `Toggle` for details.
   */
  readonly toggle: Toggle;
}

/**
 * `console` is provided by the host runtime (bridges to OSLog). Levels:
 * `log`/`info`/`trace` → info, `debug` → debug, `warn` → notice,
 * `error` → error. `warn`/`error`/`trace` automatically append a caller
 * stack trace.
 */
declare global {
  interface Console {
    log(...args: unknown[]): void;
    info(...args: unknown[]): void;
    debug(...args: unknown[]): void;
    warn(...args: unknown[]): void;
    error(...args: unknown[]): void;
    trace(...args: unknown[]): void;
  }
  // eslint-disable-next-line no-var
  var console: Console;
  // eslint-disable-next-line no-var
  var manifest: Manifest;

  /** Web Storage `Storage` minus property access. */
  interface Storage {
    readonly length: number;
    key(index: number): string | null;
    getItem(key: string): string | null;
    setItem(key: string, value: string): void;
    removeItem(key: string): void;
    clear(): void;
  }

  /**
   * Per-engine file-backed persistence. Throws on empty key, encoded
   * key > 200 bytes, or value > 10 MB. Filesystem errors log + return
   * safe defaults (null / no-op).
   */
  // eslint-disable-next-line no-var
  var localStorage: Storage;

  /**
   * Fired when `_storage/` files are modified outside this engine
   * (e.g. user editing them in Finder/CLI). The engine's own
   * setItem/removeItem/clear do NOT fire here.
   *
   * Field types follow the Web Storage spec (matches `lib.dom.d.ts`
   * declaration-merging): `key` and `storageArea` are nullable per
   * spec, though in this host they're always non-null at dispatch
   * — engines can null-check defensively or assume non-null.
   * `oldValue` is always `null` (host doesn't cache prior values).
   * `newValue` is lazy — disk is only read when a listener actually
   * accesses it, then frozen for subsequent accesses.
   */
  interface StorageEvent {
    readonly type: "storage";
    readonly key: string | null;
    readonly oldValue: string | null;
    readonly newValue: string | null;
    readonly storageArea: Storage | null;
  }

  /**
   * Web-spec listener form. For the object form, `handleEvent` is read
   * at dispatch time (reassign after registration is honored) and `this`
   * binds to the listener object.
   */
  type EventListenerOrObject<E> =
    | ((event: E) => void)
    | { handleEvent: (event: E) => void };

  function addEventListener(
    type: "storage",
    callback: EventListenerOrObject<StorageEvent>,
    options?: { once?: boolean }
  ): void;
  function addEventListener(
    type: "settingschange",
    callback: EventListenerOrObject<SettingsChangeEvent>,
    options?: { once?: boolean }
  ): void;
  function addEventListener(
    type: "menuchange",
    callback: EventListenerOrObject<MenuChangeEvent>,
    options?: { once?: boolean }
  ): void;
  function addEventListener(
    type: "togglechange",
    callback: EventListenerOrObject<ToggleChangeEvent>,
    options?: { once?: boolean }
  ): void;
  function addEventListener(
    type: "languagechange",
    callback: EventListenerOrObject<LanguageChangeEvent>,
    options?: { once?: boolean }
  ): void;
  function addEventListener(
    type: "fontcoveragechange",
    callback: EventListenerOrObject<FontCoverageChangeEvent>,
    options?: { once?: boolean }
  ): void;
  function removeEventListener(
    type: "storage",
    callback: EventListenerOrObject<StorageEvent>
  ): void;
  function removeEventListener(
    type: "settingschange",
    callback: EventListenerOrObject<SettingsChangeEvent>
  ): void;
  function removeEventListener(
    type: "menuchange",
    callback: EventListenerOrObject<MenuChangeEvent>
  ): void;
  function removeEventListener(
    type: "togglechange",
    callback: EventListenerOrObject<ToggleChangeEvent>
  ): void;
  function removeEventListener(
    type: "languagechange",
    callback: EventListenerOrObject<LanguageChangeEvent>
  ): void;
  function removeEventListener(
    type: "fontcoveragechange",
    callback: EventListenerOrObject<FontCoverageChangeEvent>
  ): void;

  /**
   * Host info and locale preferences, modeled after Web `navigator`.
   */
  interface Navigator {
    /** Most preferred BCP 47 language (e.g. `"zh-TW"`), `""` if none. */
    readonly language: string;
    /** Frozen list of BCP 47 preferences, most preferred first. */
    readonly languages: ReadonlyArray<string>;
    /** Static host identifier. See `engines/README.md` for the full format. */
    readonly userAgent: string;
  }

  /**
   * Fired on `globalThis` when system language preferences change.
   * Read `navigator.languages` for the new list.
   */
  interface LanguageChangeEvent {
    readonly type: "languagechange";
  }

  /**
   * Fired on `globalThis` when the set of font-renderable characters changes
   * (a font installed/removed). `manifest.modules.fontCoverage` already
   * reflects the new coverage; only engines that cache coverage-derived results
   * need to react.
   */
  interface FontCoverageChangeEvent {
    readonly type: "fontcoveragechange";
  }

  // eslint-disable-next-line no-var
  var navigator: Navigator;

  /**
   * Response returned by `fetch()`. Named to avoid declaration-merging
   * with `lib.dom.d.ts`'s `Response` interface — only these fields are
   * actually implemented; headers/blob/formData/clone/etc. don't exist.
   *
   * Body methods lock on entry: calling any of `text()` / `json()` /
   * `arrayBuffer()` synchronously marks the body as consumed, so a
   * second body method call rejects immediately with `Error("Body has
   * already been consumed")`. Recoverable failures (UTF-8 decode fail,
   * disk read fail, ArrayBuffer alloc fail) un-mark so the engine can
   * fall back or retry.
   */
  interface FetchResponse {
    /** Always `true` — non-2xx is not modeled (file reads either succeed or `fetch()` rejects). */
    readonly ok: boolean;
    /** Always `200`. Present for web parity, not meaningful here. */
    readonly status: number;
    /** Synthetic `engine:///<path>` URL (e.g. `"engine:///dict.json"`). */
    readonly url: string;
    /** UTF-8 decode of file contents. Rejects with `Error("Body is not valid UTF-8")` if decode fails. */
    text(): Promise<string>;
    /** Equivalent to `text().then(JSON.parse)`. Rejects with `SyntaxError` on malformed JSON. */
    json(): Promise<unknown>;
    /** Raw file bytes. */
    arrayBuffer(): Promise<ArrayBuffer>;
  }

  /**
   * Read a file from the engine folder. Two path forms:
   * - `"./<relative>"` resolves from the engine folder root
   * - `"engine:///<path>"` is an absolute synthetic URL (built from
   *   `import.meta.url` for module-relative paths)
   *
   * Parent-escapes (`../`), bare names, `file://` URLs, query strings,
   * and fragments all reject.
   *
   * `fetch()` itself stat's the file off the main thread and resolves
   * with a `FetchResponse`. The actual read happens lazily inside
   * `text()` / `json()` / `arrayBuffer()`.
   *
   * Rejects (with `Error`) on: invalid path, file not found, non-regular
   * file. Per web fetch convention, the Promise rejects rather than
   * resolving with `ok: false` for these errors.
   *
   * Fetched files are tracked alongside imports — modifying one outside
   * the engine (e.g. the user editing the file in a text editor)
   * triggers a module reload. Kick off fetches at module top level so
   * they begin on engine load and store the result into a module-scoped
   * variable via `.then(...)`; class methods read via closure. Fetching
   * inside `activate()` or the class constructor would re-read on every
   * text-field focus.
   *
   * @param init Web-fetch init bag — accepted for signature parity with
   *   the Web fetch API but **completely ignored**. Headers, method,
   *   body, cache, redirect, signal, etc. are not implemented. Passing
   *   any non-undefined value emits a runtime `console.warn`.
   */
  function fetch(input: string, init?: unknown): Promise<FetchResponse>;

  /**
   * A UTF-8-only subset of the WHATWG Encoding Standard's `TextDecoder`.
   * Converts bytes to text — typically a slice of a binary format read via
   * `fetch(...).arrayBuffer()`. For whole-file text prefer `Response.text()`
   * (decoded off the main thread by the host).
   */
  interface TextDecoder {
    readonly encoding: "utf-8";
    readonly fatal: boolean;
    readonly ignoreBOM: boolean;
    /**
     * Decode a buffer source to a string. A view's byte offset and length
     * are honored; omitting `input` decodes nothing. Invalid sequences
     * become U+FFFD unless `fatal` is set (then throws `TypeError`); a
     * leading BOM is stripped unless `ignoreBOM` is set. `stream: true`
     * holds an incomplete trailing sequence for the next call. Non-buffer
     * input throws `TypeError`.
     */
    decode(input?: ArrayBuffer | ArrayBufferView, options?: { stream?: boolean }): string;
  }

  /**
   * `label` accepts only the standard UTF-8 labels (`"utf-8"`, `"utf8"`,
   * `"unicode-1-1-utf-8"`, …); any other label throws `RangeError`, since
   * no other encoding is implemented yet.
   */
  // eslint-disable-next-line no-var
  var TextDecoder: {
    prototype: TextDecoder;
    new (label?: string, options?: { fatal?: boolean; ignoreBOM?: boolean }): TextDecoder;
  };

  /** A UTF-8-only subset of the WHATWG Encoding Standard's `TextEncoder`. */
  interface TextEncoder {
    readonly encoding: "utf-8";
    /** Encode a string to UTF-8. Unpaired surrogates become U+FFFD. */
    encode(input?: string): Uint8Array;
  }

  // eslint-disable-next-line no-var
  var TextEncoder: {
    prototype: TextEncoder;
    new (): TextEncoder;
  };
}
