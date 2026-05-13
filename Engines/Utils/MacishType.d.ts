// Type definitions for JavaScript engines loaded by MacishType.
//
// MacishType bridges to user-supplied engines via JavaScriptCore. The
// engine module's default export is duck-typed: the host calls each
// method only if defined, so every member of `InputEngine` is optional.
//
// Usage:
//   // In TypeScript
//   import type { InputEngine, KeyEvent } from "../Utils/MacishType";
//
//   // In plain JS with JSDoc
//   /** @typedef {import("../Utils/MacishType").InputEngine} InputEngine */
//   /** @implements {InputEngine} */
//   export default class MyEngine { ... }

/** Modifier flags reflect the device-independent flag mask only. */
export interface Modifiers {
  readonly shift: boolean;
  readonly ctrl: boolean;
  readonly option: boolean;
  readonly command: boolean;
}

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
   * Maps an index-label character to its page-relative 0-based candidate
   * position, or null if the character is not a valid label. Used to
   * implement quick-commit by typing a label key, paired with
   * `commitCandidateAtIndex`.
   */
  candidateIndex(char: string): number | null;
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
   * Character index into `markedText` to anchor the candidate window under.
   * Default 0 places the window below the start of the composing text;
   * larger values shift the anchor along the marked text (e.g. anchor
   * after a fixed prefix character). Indices follow the same character
   * semantics as `EmphasisRange` (grapheme clusters, not UTF-16).
   */
  offset?: number;
  /**
   * Suppress the initial selection highlight so no candidate appears
   * pre-selected. The first navigation action (arrow key, click) clears
   * the suspension and the highlight resumes for the rest of the session.
   */
  suspendHighlight?: boolean;
  /** Override the candidate window's layout direction for this update only. */
  layoutDirection?: LayoutDirection;
  /** Override the index-label characters for this update only. */
  indexLabels?: string;
  /** Override the per-page candidate count for this update only. */
  pageSize?: number;
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
   * empty array to hide the window.
   */
  updateCandidates(items: readonly CandidateInput[], options?: CandidateUpdateOptions): void;
  /** Engine-driven commit. Triggers `candidateConfirmed` if defined. */
  commit(candidate: CandidateInput): void;
  /** Commit whichever candidate is currently highlighted. */
  commitSelectedCandidate(): void;
  /**
   * Commit the candidate at the given page-relative index (0-based, within
   * the current `pageSize`). Pair with `candidateWindow.candidateIndex(char)`
   * to implement label-based quick-commit.
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
   * Enter associated-phrase mode: `heldChar` becomes staged marked text
   * and `candidates` appear as suggested follow-ups. Picking a candidate
   * commits `heldChar` followed by the chosen candidate; typing anything
   * else commits `heldChar` alone and the new key is processed normally.
   */
  enterAssociatedMode(heldChar: string, candidates: readonly string[]): void;
}

/** Context fields shared by every event payload. */
export interface EventContext {
  readonly markedText: string;
  readonly stagedText: string;
  readonly isComposing: boolean;
  readonly isAssociating: boolean;
}

/** Payload passed to `handleKey`. */
export interface KeyEvent extends EventContext, EventMutators {
  /** Raw macOS virtual key code. */
  readonly keyCode: number;
  /** Character(s) produced by the key, or null for keys with no character mapping. */
  readonly characters: string | null;
  readonly modifiers: Modifiers;
  readonly candidateWindow: CandidateWindowState;
}

/** Payload passed to `candidateConfirmed` and `candidateSelectionChanged`. */
export interface ConfirmEvent extends EventContext, EventMutators {
  /** Confirmed display text. */
  readonly candidate: string;
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
   * Returns `true` to signal the key was consumed; `false` lets the host
   * fall through to its default handling (and ultimately to the OS).
   */
  handleKey?(event: KeyEvent): boolean;
  /** Called after a candidate is committed (engine-driven or by the user). */
  candidateConfirmed?(event: ConfirmEvent): void;
  /** Called when the highlighted candidate changes (e.g. after navigation). */
  candidateSelectionChanged?(event: ConfirmEvent): void;
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
}

/**
 * Engine-wide info injected by the host.
 */
export interface Manifest {
  /**
   * User settings keyed by manifest field `key`. Deeply read-only —
   * writes throw `TypeError`. The reference is stable across updates;
   * `const { settings } = manifest` is safe and reads always see the
   * latest values.
   */
  readonly settings: Settings;

  /**
   * Candidate-window override cache. See `CandidateWindow` for details.
   */
  readonly candidateWindow: CandidateWindow;

  addEventListener(
    type: "settingschange",
    callback: (event: SettingsChangeEvent) => void
  ): void;
  removeEventListener(
    type: "settingschange",
    callback: (event: SettingsChangeEvent) => void
  ): void;
}

/**
 * `console` is provided by the host runtime (bridges to OSLog). Levels:
 * `log`/`info` → info, `debug` → debug, `warn` → notice, `error` → error.
 */
declare global {
  interface Console {
    log(...args: unknown[]): void;
    info(...args: unknown[]): void;
    debug(...args: unknown[]): void;
    warn(...args: unknown[]): void;
    error(...args: unknown[]): void;
  }
  // eslint-disable-next-line no-var
  var console: Console;
  // eslint-disable-next-line no-var
  var manifest: Manifest;
}
