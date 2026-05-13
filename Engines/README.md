# Writing a MacishType engine

A MacishType JavaScript engine is a folder picked by the user through
**Settings → JSExternal → Choose Folder…**. The host loads the folder via a
security-scoped bookmark and watches it with FSEvents, so edits show up
without a relaunch.

## Required layout

```
MyEngine/
├── manifest.json     (required)
└── index.js          (or whatever `manifest.entry` points to)
```

Optional files (loaded only if your `index.js` imports them) live wherever
you like inside the folder; `import "./foo.js"` works relative to the
importing file. Static `import` is supported; dynamic `import()` is not.

## manifest.json

```jsonc
{
  "entry": "index.js",
  "candidateWindow": { … },   // optional appearance overrides
  "settings": [ … ]           // optional Settings UI sections
}
```

### `entry` (required)

Path (relative to the manifest) to the engine's JavaScript module. The
module's `export default` must be a class — see [The JS module](#the-js-module).

### `candidateWindow` (optional)

Overrides for the candidate-window appearance. Any field may be omitted.
Invalid values are logged and ignored — the engine still loads.

Fields marked **★** are *user-overridable*: omitting them from the
manifest exposes a corresponding control in the engine's Settings UI, and
the user's choice takes precedence over the host default. Declaring the
field in the manifest removes the control from the Settings UI — the
manifest becomes the source of truth.

The other fields have no Settings UI; omitting them means the host
default below applies.

| Field | Type | Default | Notes |
|---|---|---|---|
| ★ `layoutDirection` | `"horizontal"` \| `"vertical"` | `"horizontal"` | Candidate row vs. column. |
| ★ `fontSize` | integer ≥ 8 | `16` | Point size for candidate text. |
| `indexLabels` | string | `"1234567890"` | Per-candidate label characters; ASCII-printable only (0x20-0x7E). |
| `pageSize` | integer 1–11 | `9` | Candidates per page. |
| `expandable` | boolean | `true` | Pick the horizontal-mode panel style: `true` shows a single row that expands to reveal more, `false` uses paging instead. Horizontal mode only. |
| `horizontalMaxVisibleRows` | integer ≥ 2 | `5` | Cap on visible rows. Requires `expandable: true`. |
| `widerExpandedColumns` | boolean | `true` | Widen columns when the window is expanded. Requires `expandable: true`. |
| `moveOnExpand` | boolean | `false` | When navigation expands the collapsed window, also move the selection highlight to the newly revealed row. Requires `expandable: true`. |
| `verticalMinVisibleRows` | integer ≥ 1 | `pageSize` | Minimum visible rows. Vertical mode only. |

### `settings` (optional)

Array of sections rendered in the engine's Settings tab. Each section:

```jsonc
{
  "title": "Section title" | { "en": "…", "zh-Hant": "…" },
  "description": "…",     // optional, shown below the section
  "fields": [ … ]
}
```

#### Field types

Every field shares these properties:

| Field | Type | Required | Notes |
|---|---|---|---|
| `key` | string | yes | Unique within the engine. |
| `type` | string | yes | One of `toggle`, `textField`, `number`, `picker`, `multiSelect`. |
| `label` | Localizable | yes | Row label. |
| `description` | Localizable | | Caption under the control. |
| `default` | type-specific | varies | See per-type table below. |
| `disabledWhen` | [Condition](#condition) | | Renders the field disabled when the condition holds. |
| `hiddenWhen` | [Condition](#condition) | | Renders the field hidden when the condition holds. A section with all fields hidden collapses entirely. |

##### `toggle`
| Property | Type | Required | Notes |
|---|---|---|---|
| `default` | boolean | yes | Initial state. |

##### `textField`
| Property | Type | Required | Notes |
|---|---|---|---|
| `default` | string | | Initial value. Omit for empty string. |
| `placeholder` | Localizable | | Ghost text shown when empty. |

##### `number`
| Property | Type | Required | Notes |
|---|---|---|---|
| `default` | number | yes | Initial value. |
| `min` / `max` | number | | Bounds (inclusive). |
| `step` | number | | Stepper increment; integer step formats display as integer. |

##### `picker`
| Property | Type | Required | Notes |
|---|---|---|---|
| `options` | [PickerOption](#pickeroption)`[]` | yes | Selectable options. |
| `default` | integer \| string | | Index or tag of the chosen option. Omit → first option. |
| `style` | `"auto"` \| `"menu"` \| `"radioGroup"` | | `"auto"` picks `radioGroup` when ≤ 3 options, else `menu`. |

##### `multiSelect`
| Property | Type | Required | Notes |
|---|---|---|---|
| `options` | [PickerOption](#pickeroption)`[]` | yes | Selectable options. |
| `default` | (integer \| string)`[]` | | Indices or tags of pre-selected options. Omit → empty selection. |

#### Localizable

A field that accepts a localized value can be either a literal string or a
locale map:

```jsonc
"label": "Show associated words"
"label": { "en": "Show associated words", "zh-Hant": "顯示關聯字" }
```

Resolution order: `Bundle.main.preferredLocalizations` → `"en"` →
lowest-sorted key (deterministic).

#### PickerOption

Three accepted forms:

```jsonc
// 1. Shorthand string — text, value, and tag all equal "pinyin".
"pinyin"

// 2. Object with literal text — value/tag default to the text string.
{ "text": "Bopomofo" }
{ "text": "Bopomofo", "value": "bopo" }    // value explicit, tag = "Bopomofo"

// 3. Object with localized text — value MUST be explicit; tag still optional.
{
  "text": { "en": "Pinyin", "zh-Hant": "拼音" },
  "tag":  "pinyin",
  "value": { "engine": "phonetic", "subtype": "pinyin" }
}
```

| Property | Type | Required | Notes |
|---|---|---|---|
| `text` | Localizable | yes | Display string. |
| `value` | JSON value (string / number / boolean / array / object / null) | conditional | What gets stored when this option is chosen. Required when `text` is localized; otherwise defaults to the text literal. |
| `tag` | string | | Stable identifier for `default` references. Defaults to the text literal when text is a string. |

`default` as a string matches **tags only**, never values — values may be
objects or arrays, so string equality wouldn't generalize. Picker authors
who want to reference by value should add an explicit tag with the same
name.

#### Condition

Used for `disabledWhen` and `hiddenWhen`. Recursive boolean over the
current settings snapshot:

```jsonc
// Leaf — one operator per condition.
{ "key": "filterMode", "equals": "all" }
{ "key": "filterMode", "notEquals": "all" }
{ "key": "filterMode", "in":    ["include", "exclude"] }
{ "key": "filterMode", "notIn": ["include", "exclude"] }

// Composite.
{ "allOf": [ … ] }
{ "anyOf": [ … ] }
{ "not":    { … } }

// Array at top level → implicit allOf.
[ { … }, { … } ]
```

`equals` / `notEquals` accept any JSON value (matches the option's
`value`, with deep equality for objects and arrays). Missing keys
evaluate to `null`, so `notEquals` / `notIn` against a typo'd key flip
to permanently true — diff-check key references when renaming a field.

## The JS module

`manifest.entry` resolves to a JavaScript module whose `export default` is
a class. The class is **instantiated once per text-field session**, so
per-field state lives on `this`.

```js
/** @typedef {import("../Utils/MacishType").InputEngine} InputEngine */
/** @typedef {import("../Utils/MacishType").KeyEvent}     KeyEvent     */
/** @typedef {import("../Utils/MacishType").ConfirmEvent} ConfirmEvent */

/** @implements {InputEngine} */
export default class MyEngine {
  activate()    { /* per-session setup */ }
  deactivate()  { /* per-session teardown */ }

  /** @param {KeyEvent} event */
  handleKey(event) {
    // return true  → key consumed
    // return false → fall through to OS
  }

  /** @param {ConfirmEvent} event */
  candidateConfirmed(event) { /* committed */ }

  /** @param {ConfirmEvent} event */
  candidateSelectionChanged(event) { /* highlight moved */ }
}
```

Every method is **optional** — the host calls only those defined on the
instance. The full type surface lives in
[`Utils/MacishType.d.ts`](Utils/MacishType.d.ts) and is the source of
truth. Highlights:

### Lifecycle

- `activate()` — fires when focus enters a text field.
- `deactivate()` — fires when focus leaves. The host automatically calls
  `resetContext()` on its side (clearing marked text, staged text,
  candidates, associated-mode state), but engine-private state on `this`
  (composition buffers, mode flags, lookup caches per session, etc.) is
  not touched — clear it here, otherwise it leaks into the next session.
- `handleKey(event)` — return `true` to consume the key, `false` to let
  the OS see it.
- `candidateConfirmed(event)` — after the host commits a candidate
  (engine-driven or user-picked).
- `candidateSelectionChanged(event)` — after the highlight moves (e.g.
  arrow keys).

### Event mutators

Every event object carries the same mutator surface. Calls are **queued**
and applied after the engine method returns — reading `event.markedText`
right after `event.updateMarkedText(…)` still returns the snapshot from
method entry.

All character-index parameters (`cursor`, `staged`, `emphasis`, `offset`)
count **extended grapheme clusters**, not UTF-16 code units. See
[Character indices](#character-indices) for the alignment helper.

#### `updateMarkedText(text, options?)`

Replace the composing (marked) text shown in the active text field.

- `text` *(string, required)* — new composing text. An empty string clears the composition.
- `options.cursor` *(integer)* — caret position within `text`. Omit to default to end-of-text; `0` explicitly places the caret at the start. **`0` is distinct from omission.**
- `options.staged` *(integer)* — number of leading characters that will be committed when the composition ends. Negative stages the whole text. Use with `flushStaged()` to write the prefix out.
- `options.emphasis` *(`{ start, end }`)* — sub-range to render with emphasis (e.g. thicker underline). `start` inclusive, `end` exclusive.

#### `updateCandidates(items, options?)`

Replace the candidate list shown in the candidate window.

- `items` *(array, required)* — each entry is either a plain string or `{ candidate, annotation?, payload? }`:
  - `candidate` *(string)* — display text shown in the window.
  - `annotation` *(string)* — optional disambiguator shown beside the candidate (e.g. description of a symbol).
  - `payload` *(any)* — opaque value round-tripped back via `candidateConfirmed` / `candidateSelectionChanged`, so engines can attach IDs without parsing display text.
- Pass an **empty array** to hide the window.
- `options.offset` *(integer, default `0`)* — character index into `markedText` to anchor the window under. `0` places it below the start; larger values shift the anchor along the marked text (e.g. after a fixed prefix).
- `options.suspendHighlight` *(boolean, default `false`)* — when `true`, no candidate appears pre-selected. The first navigation action (arrow key, click) clears the suspension and the highlight resumes for the rest of the session.
- `options.layoutDirection` *(`"horizontal"` \| `"vertical"`)* — override the candidate window's layout direction for this update only.
- `options.indexLabels` *(string)* — override the index-label characters for this update only.
- `options.pageSize` *(integer)* — override the per-page candidate count for this update only.

#### `commit(candidate)`

Engine-driven commit; triggers the `candidateConfirmed` callback so the
engine can run its post-commit pipeline (associated mode, etc.).

- `candidate` *(string or `{ candidate, annotation?, payload? }`)* — what to commit. Same shape as items in `updateCandidates`.

#### `commitSelectedCandidate()`

Commit whichever candidate is currently highlighted in the window. Used
when the user presses Enter / Space.

#### `commitCandidateAtIndex(index)`

Commit the candidate at a page-relative position.

- `index` *(integer, required)* — 0-based position within the current
  `pageSize`. Pair with `event.candidateWindow.candidateIndex(char)` to
  implement label-based quick-commit:

  ```js
  const idx = event.candidateWindow.candidateIndex(event.characters);
  if (idx !== null) event.commitCandidateAtIndex(idx);
  ```

#### `navigateCandidates(direction, options?)`

Move the candidate-window selection.

- `direction` *(string, required)* — physical-key directions are grouped first; the layout-independent ones below are typically used for engine logic rather than direct key binding.
  - `"up"` / `"down"` / `"left"` / `"right"` — single-step in that direction.
  - `"home"` / `"end"` — first / last candidate in the current scope. Scope varies by panel style: current page in horizontal paging mode, current row in horizontal expandable mode, entire list in vertical mode.
  - `"pageUp"` / `"pageDown"` — keyboard PageUp / PageDown semantics (visual viewport scroll). Identical to `pageBackward` / `pageForward` in horizontal paging and vertical modes. In horizontal expandable mode, scrolls the viewport by `horizontalMaxVisibleRows − 1` rows (one row of overlap kept for context) — *not* the same as `pageForward` / `pageBackward`, which step a single row in that mode.
  - `"itemForward"` / `"itemBackward"` — next / previous candidate regardless of layout direction.
  - `"pageForward"` / `"pageBackward"` — advance / retreat one candidate page regardless of layout direction. In horizontal expandable mode, "one page" is one row.
- `options.wrapping` *(boolean, default `false`)* — wrap around when navigating past the first / last candidate.

#### `resetContext()`

Clear marked text, candidates, staged text, and associated-mode state in
one call. Use for Esc-like flows that abandon the in-progress composition.

#### `flushStaged(append?)`

Commit the staged prefix (set via `updateMarkedText({ staged: … })`) and
optionally append more text.

- `append` *(string, optional)* — text appended after the staged prefix in the same commit. Call with no argument to flush whatever was staged.

#### `enterAssociatedMode(heldChar, candidates)`

Enter associated-phrase mode: `heldChar` becomes staged marked text and
`candidates` appear as suggested follow-ups. Picking a candidate commits
`heldChar + chosen`; typing anything else commits `heldChar` alone and
the new key is processed normally.

- `heldChar` *(string, required)* — the just-committed character to keep as the staged prefix.
- `candidates` *(string[], required)* — follow-up suggestions to show in the candidate window.

### Event context (read-only)

| Field | Description |
|---|---|
| `markedText` | Current composing text. |
| `stagedText` | Prefix already staged for commit. |
| `isComposing` | Whether marked text is non-empty. |
| `isAssociating` | Whether the engine is in associated-phrase mode. |

`KeyEvent` additionally has `keyCode` (macOS virtual key code),
`characters` (string \| null), `modifiers` (`{ shift, ctrl, option, command }`),
and `candidateWindow` (snapshot at method entry).

`ConfirmEvent` additionally has `candidate`, `annotation?`, and
`payload?` (round-tripped from the original `Candidate`).

### Character indices

`EmphasisRange`, `MarkedTextOptions.cursor`, and
`CandidateUpdateOptions.offset` count **extended grapheme clusters**, not
UTF-16 code units. Use `Intl.Segmenter` to get aligned counts:

```js
const seg = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const characterCount = [...seg.segment(markedText)].length;
```

### Runtime globals

The host injects `console` and `manifest` into the engine's global scope.

#### `console`

Levels map to OSLog:

```
console.log   / console.info  → OSLog .info
console.debug                 → OSLog .debug
console.warn                  → OSLog .notice
console.error                 → OSLog .error
```

No `require`, `process`, `setTimeout`, network, or filesystem APIs are
exposed. Engines run inside JavaScriptCore.

#### `manifest`

Engine-wide info injected by the host.

##### `manifest.settings`

Read-only snapshot of the user's current settings, keyed by the manifest
`key`. Values match the field's declared schema after host sanitize —
a `toggle` field's value is always a boolean, etc.

```js
const showAssoc = manifest.settings.showAssociatedWords;
```

Populated before engine module evaluation (read at module top level
works). Refreshes at two boundaries: any host-driven manifest reload
(folder change, FSEvents in import graph) and the start of each new
text-field session (the host re-reads UserDefaults on activate). UI
edits made between sessions are visible to the engine on the next
session boundary; mid-composition edits aren't pushed in real time.
`settingschange` fires whenever the values actually change.

The reference is stable across updates; destructuring is fine:

```js
const { settings } = manifest;
// keep using `settings` — content stays in sync with host pushes
```

Deeply read-only — writes throw `TypeError`.

##### `manifest.addEventListener('settingschange', callback)`

Fired when `manifest.settings` content changes (deep-equal dirty check;
no spurious events). The callback receives `{ type: 'settingschange' }`
— read `manifest.settings` for the current values.

##### `manifest.removeEventListener('settingschange', callback)`

Standard DOM-style detach.

Attach at module scope, not on an instance — settings are engine-wide
and the listener registry only resets on engine reload (folder change,
file edit), so per-instance attach both confuses ownership and leaks
`this` across text-field sessions.

Most code should just read `manifest.settings` at the point of use:

```js
export default class MyEngine {
  handleKey(event) {
    if (manifest.settings.showAssociatedWords) { ... }
  }
}
```

Attach a listener only when a settings change should trigger expensive
work — reloading a dictionary, rebuilding a trie, recompiling a regex:

```js
let dictionary = loadDictionary(manifest.settings.dictionaryPath);
manifest.addEventListener('settingschange', () => {
  dictionary = loadDictionary(manifest.settings.dictionaryPath);
});
```

##### `manifest.candidateWindow`

Live candidate-window configuration. Reads return what engine code wrote
(if any), else the manifest declaration, else `undefined`. Writes
override individual fields by direct assignment.

**Writes are not immediate — they take effect at the next session
activate.** The host reads the latest values when it configures the
candidate window at each activate boundary, so the canonical pattern
is to write during module setup or in a `settingschange` listener;
those flows run before/during an activate and naturally line up with
the configure call. For per-event tweaks (mid-composition layout
changes, etc.), use `event.updateCandidates(items, { ... })` overrides
instead.

```js
function applyConfig() {
  manifest.candidateWindow.indexLabels = manifest.settings.candidateKeys;
}
applyConfig();
manifest.addEventListener('settingschange', applyConfig);
```

**Failed writes never throw** — invalid values (wrong type, out of
range, non-ASCII `indexLabels`, etc.) and unknown field names are
logged via OSLog and silently ignored. This is deliberate for
forward/backward compat: engines written against a newer or older host
run uninterrupted on field/value mismatches. Read back after writing
if you need to confirm:

```js
manifest.candidateWindow.indexLabels = "あいう";  // not ASCII printable
manifest.candidateWindow.indexLabels;              // ← previous value
```

**Reads return cache state**, not the *effective* configuration. If
manifest didn't declare `fontSize` and the user picked 18 via the
Settings UI, the actual candidate window uses 18 but
`manifest.candidateWindow.fontSize` reads `undefined`. For the
effective state during a key event, use `event.candidateWindow`.

**Don't confuse with `event.candidateWindow`** (on `KeyEvent`) — that's
a per-event snapshot of what the user is currently seeing; this is the
engine's override cache.

`Object.assign(manifest.candidateWindow, { ... })` works — each field
flows through the Proxy independently. Invalid fields warn and skip;
valid ones still commit.

**Overriding user-controllable fields**: writing `layoutDirection` or
`fontSize` here silently wins over the user's Settings UI choice (the
control stays visible but the user's change has no effect). If the
engine intends to manage these itself, declare a placeholder value in
`manifest.json`'s `candidateWindow` to hide the corresponding Settings
UI control, then drive the actual value through this object.

## TypeScript hint

`Utils/MacishType.d.ts` ships with the project. Plain JS engines can pull
type hints in via JSDoc:

```js
/** @typedef {import("../Utils/MacishType").InputEngine} InputEngine */
/** @typedef {import("../Utils/MacishType").KeyEvent}     KeyEvent     */
```

TypeScript engines can `import type` directly:

```ts
import type { InputEngine, KeyEvent } from "../Utils/MacishType";
```

