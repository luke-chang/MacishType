# Writing a MacishType JavaScript engine

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
  "name": "My Engine",           // optional display name, Localizable
  "intendedLanguage": "zh-Hant", // optional language override
  "candidateWindow": { … },      // optional appearance overrides
  "modules": { … },              // optional host-provided data tables
  "capabilities": { … },         // optional host-feature declarations
  "settings": [ … ],             // optional Settings UI sections
  "menu": [ … ]                  // optional IME-menu items
}
```

### `entry` (required)

Path (relative to the manifest) to the engine's JavaScript module. The
module's `export default` must be a class — see [The JS module](#the-js-module).

### `name` (optional)

Display name for the engine, shown in the Settings window title appended to
the host's slot label — e.g. with a `name` of `"行列"` the title reads
`"JS (行列)"`. Omitting it (or a value that resolves empty) leaves just the
slot label.

Accepts a literal string or a [Localizable](#localizable) locale map:

```jsonc
"name": "Array"
"name": { "en": "Array", "zh-Hant": "行列" }
```

Also readable at runtime as `manifest.name` (already resolved to the active
locale, or `undefined` when undeclared).

### `intendedLanguage` (optional)

BCP 47 language tag declaring the language this engine targets. Overrides the
`TISIntendedLanguage` the host declares for the engine slot in Info.plist —
useful because that slot value is fixed at install time and can't change at
runtime, while a loaded engine may target a different language.

Use the **Apple / in-bundle localization** convention — the same tags as your
`Localizable` map keys and the host's `TISIntendedLanguage` (language + script,
e.g. `zh-Hant`, `en`, `ja`). This is **not** the region style that
`navigator.language` reports (`zh-TW`); the two describe different things
(engine target vs. user preference) and the host matches this value exactly,
so `zh-TW` would not resolve. Omitting the field keeps the plist value.

Currently consumed by the associated-mode dictionary lookup (see
[`system`](#system)); future host features may read it too.

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
| `indexLabels` | string | `"1234567890"` | Per-candidate label characters; ASCII-printable only (0x20-0x7E), which includes space (see below). |
| `pageSize` | integer 1–11 | `9` | Candidates per page. |
| `expandable` | boolean | `true` | Pick the horizontal-mode panel style: `true` shows a single row that expands to reveal more, `false` uses paging instead. Horizontal mode only. |
| `horizontalMaxVisibleRows` | integer ≥ 2 | `5` | Cap on visible rows. Requires `expandable: true`. |
| `widerExpandedColumns` | boolean | `true` | Widen columns when the window is expanded. Requires `expandable: true`. |
| `moveOnExpand` | boolean | `false` | When a navigation key expands the collapsed window, also move the highlight onto the newly revealed row. Applies to `down` and `pageForward`; `pageDown` always just expands without moving. Pair with `widerExpandedColumns: false` so columns don't reflow on expand and the landing highlight is predictable. Requires `expandable: true`. |
| `verticalMinVisibleRows` | integer ≥ 1 | `pageSize` | Minimum visible rows. Vertical mode only. |
| `handleNavigationKeys` | boolean | `true` | When true, the host intercepts standard nav keys (arrows / Tab / Page / Home / End) and Enter while the candidate window is visible — `handleKey` / `handleAssociatedKey` never see them. Set false to route those keys to the engine. |
| `handleIndexLabelKeys` | boolean | `true` | When true, the host intercepts `indexLabels` keys while the candidate window is visible. Set false to route them to the engine. |

`indexLabels` distinguishes two empty-looking values:

- `""` collapses the index column entirely — candidates render with no
  label slot reserved.
- `" "` (or any string containing only whitespace) keeps the slot
  reserved but renders blank. Use this when you want consistent
  alignment with engines that do show labels, or when only some
  positions should display a character (shorter-than-`pageSize` labels
  pad the tail with blanks while keeping slots reserved).

Whitespace can also appear mid-string — e.g. `" 123"` is valid and
makes position 0 blank while positions 1-3 render `"1"` / `"2"` / `"3"`.
Whitespace characters anywhere in `indexLabels` never match an
index-label key input — `event.candidateWindow.candidateIndex(" ")`
returns `null`, so the space key remains available for engine logic.

### `modules` (optional)

Opt-in host-provided data, injected into the runtime at load — before your
entry module evaluates — so you read it synchronously without shipping or
parsing the data yourself. Each field is a boolean; `true` requests that module.

| Field | Type | Provides | `query(key)` returns |
|---|---|---|---|
| `fontCoverage` | boolean | Whether a value is renderable by an installed font (e.g. `"的"` → `true`). | `true` / `false` |
| `symbolNames` | boolean | Symbol → human-readable name (e.g. `"！"` → `"驚嘆號"`). | name, or `undefined` |
| `wordFrequency` | boolean | Character → frequency count (e.g. `"的"` → `615175`), higher is more common. | count, or `0` |

`symbolNames` / `wordFrequency` are static tables picked by the engine's
*resolved* [`intendedLanguage`](#intendedlanguage) — the manifest field if
declared, otherwise the host's plist `TISIntendedLanguage`. `fontCoverage` is
computed live from installed fonts (locale-independent) and stays current: when
fonts are installed/removed `query` reflects the new coverage with no reload,
and a [`fontcoveragechange`](#event-fontcoveragechange) event fires.

```jsonc
"modules": {
  "fontCoverage": true,
  "symbolNames": true,
  "wordFrequency": true
}
```

At runtime each enabled module is exposed on `manifest.modules.<name>` as a
**frozen, read-only view exposing `query(key)`**:

```js
const { fontCoverage, symbolNames, wordFrequency } = manifest.modules;
fontCoverage.query("的");    // true       (absent → false)
symbolNames.query("！");     // "驚嘆號"   (absent → undefined)
wordFrequency.query("的");   // 615175     (absent → 0)
```

The absent-key result is per module (see the table above). For `fontCoverage`,
`query` checks that **every** scalar of the argument is renderable (so a
multi-scalar value — phrase, IVS/emoji sequence — is `true` only if all of it
renders). A module you enabled is **always present** — a lookup table with no
data for the resolved language is an empty view (every `query` returns its miss
value) rather than a missing property, so engine code never has to guard for
absence. The view *references* are stable — injected once and never replaced —
so reading or destructuring them at module top level is safe; note that
`fontCoverage`'s `query` *results* still change as fonts change (the object is
the same, its backing data updates).

### `capabilities` (optional)

Declares which optional host features the engine's class implements. Unlike
`modules` (data the host injects into JS), these flags describe what the host
may call on the engine; they are host-only and **not** exposed on the JS
global `manifest`.

```jsonc
"capabilities": {
  "reverseLookup": true
}
```

#### `reverseLookup`

Declaring `"reverseLookup": true` lists the engine in the host's Find Input
Code window and lets the host call a **static** method on the default-export
class:

```js
export default class MyEngine {
  /**
   * All input codes that produce `character` in this engine.
   * @param {string} character - a single user-perceived character
   *   (grapheme cluster). Its `.length` can exceed 1 (surrogate pairs,
   *   combining marks) — don't assume `length === 1`.
   * @returns {(string | {code: string, annotation?: string})[]}
   *   Plain code strings, or objects carrying an optional short label the
   *   host renders dimmed next to the code. Return `[]` for no codes.
   */
  static reverseLookup(character) {
    return [];
  }
}
```

The method is static because reverse lookup isn't tied to any text-field
session. Declaring the capability without defining the method is harmless —
every query just returns no codes.

Two further optional statics manage the lookup data's lifecycle:

```js
export default class MyEngine {
  /**
   * Awaited by the host before reverse lookups. Resolve when the data is
   * ready — await the table fetch and build the reverse index here.
   * Idempotency should come from null-checking the built index, not from
   * caching this promise. A rejected promise — or a synchronous throw —
   * marks the engine as failed for this lookup session. Must eventually
   * settle (drive it from fetch promises). Absent = ready right after
   * module load.
   */
  static async prepareReverseLookup() {}

  /**
   * Called when the lookup session for this engine ends. Release
   * lookup-only state built by prepare. May arrive while a prepare promise
   * is still pending — a late prepare may then rebuild the index (kept
   * until the next end or module unload; the host discards the abandoned
   * query's results). Engines whose reverse data is shared with the typing
   * path must NOT declare this.
   */
  static endReverseLookup() {}
}
```

The typed contract for the static side is `InputEngineConstructor` in
`Utils/MacishType.d.ts`; see the TypeScript hint section for how to check
it with `satisfies`.

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

The standard field types (`toggle`, `textField`, `number`, `picker`,
`multiSelect`) share these properties:

| Field | Type | Required | Notes |
|---|---|---|---|
| `key` | string | yes | Unique within the engine. |
| `type` | string | yes | One of `toggle`, `textField`, `number`, `picker`, `multiSelect`. |
| `label` | Localizable | yes | Row label. |
| `description` | Localizable | | Caption under the control. |
| `default` | type-specific | varies | See per-type table below. |
| `disabledWhen` | [Condition](#condition) | | Renders the field disabled when the condition holds. |
| `hiddenWhen` | [Condition](#condition) | | Renders the field hidden when the condition holds. A section with all fields hidden collapses entirely. |

There's also a `system` field type, which renders host-provided UI and
has its own minimal schema — see [`system`](#system) below.

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

##### `system`

Renders a host-provided control (UI, label, and storage all live on the
host side). Use this to expose a system feature in your engine's Settings
without having to model it in your manifest. Reading the field's value from
JS works the same as any other field: `manifest.settings[key]`.

The schema is minimal — only `key`, `type`, and `default` are accepted;
`label`, `description`, `disabledWhen`, `hiddenWhen` etc. do not apply.

| Property | Type | Required | Notes |
|---|---|---|---|
| `key` | string | yes | System feature identifier. Currently the only supported value is `"enableAssociatedMode"`, which requires the host to bundle an associated-mode dictionary for the engine's resolved language (see below). |
| `default` | boolean | | Initial value applied the first time this engine loads, before the user has made a choice. Omit and the host's own default is used. |

```jsonc
{
  "title": { "en": "Typing", "zh-Hant": "輸入行為" },
  "fields": [
    {
      "key": "enableAssociatedMode",
      "type": "system",
      "default": true
    }
  ]
}
```

When `enableAssociatedMode` is on, calling `event.enterAssociatedMode(heldChar)`
without a second argument falls back to the host's `AssociatedDictionary`
dictionary keyed by the engine's resolved language — the manifest
[`intendedLanguage`](#intendedlanguage-optional) if declared, otherwise the
plist `TISIntendedLanguage`.

If the host bundles no `AssociatedDictionary.<locale>.txt` for that resolved
language, the system field is treated as if it were never declared: the toggle
doesn't appear in Settings, no default is written, and the value isn't pushed to
`manifest.settings`. (Engines that supply their own `candidates` array to
`enterAssociatedMode` are unaffected — that path never consults the host
dictionary.)

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

### `menu` (optional)

Items for the engine's section of the IME menu (the input-source menu in
the menu bar). A flat array — no sections. Declaring it is an
all-or-nothing takeover:

- **absent** — the host contributes its default items. For engines whose
  resolved language is `zh-Hant` that's the Traditional→Simplified
  conversion toggle; other languages get no items.
- **`[]`** — no items at all, including the host defaults.
- **non-empty** — exactly the declared items, in order. A `zh-Hant`
  engine that declares a non-empty `menu` must list `outputToSimplified`
  itself or the conversion toggle disappears.

```jsonc
"menu": [
  { "key": "outputToSimplified", "type": "system" },
  { "type": "divider" },
  {
    "key": "strictMode",
    "type": "toggle",
    "label": { "en": "Strict matching", "zh-Hant": "嚴格比對" },
    "default": false,
    "disabledWhen": { "key": "outputToSimplified", "equals": true }
  }
]
```

Item values are readable and writable at runtime via
[`manifest.menu`](#manifestmenu); the user flips them from the IME menu.
Broken items are dropped + logged; duplicate keys keep the first
declaration.

#### Item types

##### `toggle`

An engine-defined boolean, rendered as a check-markable menu item. Same
schema as the settings [`toggle`](#toggle) minus `description`
(`default` is required):

| Property | Type | Required | Notes |
|---|---|---|---|
| `key` | string | yes | Value key. Unique within `menu`; must not start with `settings.` (reserved for condition references). May collide with a `settings` key — the two are separate namespaces with separate storage. |
| `label` | Localizable | yes | Menu item title. |
| `default` | boolean | yes | Initial value. |
| `disabledWhen` / `hiddenWhen` | Condition | | See [conditions](#menu-conditions) below. |

##### `system`

Borrows a host-provided menu feature — the host supplies the title, the
keyboard shortcut, and the storage:

| Property | Type | Required | Notes |
|---|---|---|---|
| `key` | string | yes | Feature identifier. Currently the only supported value is `"outputToSimplified"` — the Traditional→Simplified commit transform. |
| `label` | Localizable | | Overrides the host title. Providing it means taking over the presentation: the host keyboard shortcut is dropped too. Omit to keep the host title and shortcut. |
| `default` | boolean | | Initial value applied the first time this engine loads, before the user has made a choice. |
| `disabledWhen` / `hiddenWhen` | Condition | | See [conditions](#menu-conditions) below. |

Declaring `outputToSimplified` also lifts its language gate: the feature
works regardless of the engine's resolved language (without a declared
`menu` it only applies to `zh-Hant`).

##### `divider`

A separator line. No key, no value. Accepts an optional `hiddenWhen` so
a divider can disappear together with the group it separates.

#### Menu conditions

`disabledWhen` / `hiddenWhen` use the same [Condition](#condition)
grammar as settings fields, evaluated each time the menu opens. Leaf
`key` references resolve against:

- **bare key** — another `menu` item's current value;
- **`settings.<key>`** — a settings field's current value.

Settings conditions cannot reference menu items — the dependency only
goes one way.

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
    // return false → fall through to OS (queued mutators still apply)
  }

  /** @param {ConfirmEvent} event */
  candidateConfirmed(event) { /* committed */ }

  /** @param {ConfirmEvent} event */
  candidateSelectionChanged(event) { /* highlight moved */ }

  compositionEnded() { /* composition ended — clear this-state */ }
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
  (mode flags, lookup caches per session, etc.) is not touched. Use this
  for session-level teardown; for composition state held on `this`, prefer
  `compositionEnded()` (below), which also fires on this path.
- `handleKey(event)` — return `true` to consume the key. Returning
  `false` / `undefined` (including omitting the method) lets the OS
  see it. Queued `event.xxx(...)` mutators apply regardless of the
  return value; the return value only governs OS passthrough.

  While the candidate window is visible, the host intercepts standard
  nav keys (arrows / Tab / Page / Home / End), Enter, and `indexLabels`
  keys **before** `handleKey` runs — by default the engine
  never sees them. Turn off `handleNavigationKeys` /
  `handleIndexLabelKeys` (manifest or per-update options) to route
  those keys to the engine instead.

  For nav-key opt-out, `event.candidateWindow.navigationIntent(event)`
  returns the same `{ direction, options }` pair the host would use,
  or `null` for non-nav keys — pass it straight to `navigateCandidates`
  instead of rebuilding the keyCode → direction table:

  ```js
  const intent = event.candidateWindow.navigationIntent(event);
  if (intent) {
    event.navigateCandidates(intent.direction, intent.options);
    return true;
  }
  ```
- `handleAssociatedKey(event)` — called in associated mode for keys
  the candidate window didn't handle (keys outside its scope, or
  in-scope keys when `handleNavigationKeys` / `handleIndexLabelKeys`
  is off — see `handleKey` above). Return `true` to consume the key.
  Returning `false` / `undefined` (including omitting the method)
  makes the host dismiss associated mode and process the key fresh
  via `handleKey`.

  Omitting the method gives the host default: Escape calls
  `flushStaged()` to dismiss; other keys fall through.
- `candidateConfirmed(event)` — after the host commits a candidate
  (engine-driven or user-picked). See [Host fallback](#host-fallback) for
  the return-value contract.
- `candidateSelectionChanged(event)` — after the highlight moves (e.g.
  arrow keys). Same return-value contract as `candidateConfirmed`.
- `compositionEnded()` — fires when the host ends composition: an in-app
  commit (mouse click elsewhere, Cmd+A) or session `deactivate()` (app
  switch, focus loss). Clear any composing state held on `this` here. The
  `deactivate` path can fire it with nothing composing (e.g. switching
  apps), so keep it idempotent.

#### Numeric keypad keys

Recommended convention (what macOS input methods do): keypad character
keys — every `code` starting with `"Numpad"` except `"NumpadEnter"` —
never enter the composition. Swallow them while composing, pass them
through when idle, before interpreting characters:

```js
if (event.code.startsWith("Numpad") && event.code !== "NumpadEnter"
    && !event.metaKey && !event.ctrlKey && !event.altKey) {
  return event.isComposing;   // swallow while composing, pass through when idle
}
```

While the candidate window is visible, keypad digits matching an index
label are consumed by the host's label dispatch before `handleKey`
reaches the engine (it matches by character, so keypad and main-row
digits select alike).

Two named keypad keys:

- **NumpadEnter** should behave like Return — compare
  `event.key === "Enter"`, which covers both.
- **Clear** has `code: "NumLock"` (W3C position semantics) and
  `key: "Clear"`. Treat it like Escape while composing (match
  `event.key === "Clear"` alongside `"Escape"`); when idle let it pass
  through for the client to handle.

#### Host fallback

`candidateConfirmed` and `candidateSelectionChanged` share a single
contract for delegating back to the host's built-in behavior.

Return `true` to mark the callback as **handled** — the host applies any
queued mutators and stops there.

Return `false` / `undefined` (or omit the method) to **fall back**. Queued
mutators still apply, but the host then layers its default behavior on
top of them.

**Fallback for `candidateConfirmed`**:

1. If `event.isAssociating` is true → flush the staged prefix together
   with this committed character, then exit associated mode.
2. Else if `event.candidate.length === 1` AND
   `manifest.settings.enableAssociatedMode` is true AND the host's
   `AssociatedDictionary` dictionary has follow-ups for that character →
   enter associated mode with those follow-ups.
3. Otherwise → flush staged.

**Fallback for `candidateSelectionChanged`**: nothing happens (host emits
no actions). The hook exists so future host defaults can apply
automatically.

To intentionally **suppress** fallback with no side effect, return `true`
from an empty body. A bare `return;` or omitting the method triggers
fallback.

### Event mutators

Every event object carries the same mutator surface. Calls are **queued**
and applied after the engine method returns — reading `event.markedText`
right after `event.updateMarkedText(…)` still returns the snapshot from
method entry.

All character-index parameters (`cursor`, `staged`, `emphasis`, `anchorAt`)
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
- `options.anchorAt` *(integer, default `0`)* — cursor position in `markedText` where the window's left edge anchors. Range `0...markedText.length`: `0` = before the first character, `length` = after the last.
- `options.initialHighlight` *(integer, default `0`)* — initial selection. `0` highlights the first candidate; a positive `n` highlights absolute index `n` (clamped to the displayed range, independent of `pageSize`); `-1` suspends the initial highlight — the first navigation action reveals it and normal behavior resumes.
- `options.layoutDirection` *(`"horizontal"` \| `"vertical"`)* — override the candidate window's layout direction for this update only.
- `options.indexLabels` *(string)* — override the index-label characters for this update only. Same `""`-collapses-vs-`" "`-blank-slot semantics as the manifest field.
- `options.pageSize` *(integer)* — override the per-page candidate count for this update only.
- `options.handleNavigationKeys` *(boolean)* — override host nav-key handling for this update only.
- `options.handleIndexLabelKeys` *(boolean)* — override host index-label key handling for this update only.

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
  commit by index label:

  ```js
  // event.key is the layout-aware character (or a named string like "Tab"
  // for non-printable keys), so guard on length before treating it as a
  // candidate-label char.
  if (event.key && event.key.length === 1) {
    const idx = event.candidateWindow.candidateIndex(event.key);
    if (idx !== null) event.commitCandidateAtIndex(idx);
  }
  ```

#### `navigateCandidates(direction, options?)`

Move the candidate-window selection.

- `direction` *(string, required)* — physical-key directions are grouped first; the layout-independent ones below are typically used for engine logic rather than direct key binding.
  - `"up"` / `"down"` / `"left"` / `"right"` — single-step in that direction.
  - `"home"` / `"end"` — first / last candidate in the current scope. Scope varies by panel style: current page in horizontal paging mode, current row in horizontal expandable mode, entire list in vertical mode.
  - `"pageUp"` / `"pageDown"` — keyboard PageUp / PageDown semantics. Identical to `pageBackward` / `pageForward` in horizontal paging and vertical modes. In horizontal expandable mode they page by a full `horizontalMaxVisibleRows` rows, keeping the highlight's relative position in the viewport and clamping to the first / last row (pageUp on the first row collapses the window) — unlike `pageForward` / `pageBackward`, which step a single row.
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

#### `enterAssociatedMode(heldChar, candidates?)`

Enter associated mode: `heldChar` becomes staged marked text and
`candidates` appear as suggested follow-ups. Picking a candidate commits
`heldChar + chosen`; typing anything else commits `heldChar` alone and
the new key is processed normally.

- `heldChar` *(string, required)* — the just-committed character to keep as the staged prefix.
- `candidates` *(string[], optional)* — follow-up suggestions. Omit to fall
  back to the host's `AssociatedDictionary` dictionary keyed by `heldChar`'s
  first character. The fallback requires the manifest to opt in via
  `{ "key": "enableAssociatedMode", "type": "system" }` and the toggle to
  be on; otherwise the lookup yields an empty list and associated mode
  is not entered.

### Event context (read-only)

| Field | Description |
|---|---|
| `markedText` | Current composing text. |
| `stagedText` | Prefix already staged for commit. |
| `isComposing` | Whether marked text is non-empty. |
| `isAssociating` | Whether the engine is in associated mode. |
| `candidateWindow` | Snapshot of the candidate window state at method entry. |

`KeyEvent` field names and semantics track web
[`KeyboardEvent`](https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent):

- `key` — layout-aware key value: the character produced (`"a"` / `"A"` /
  `"!"`) for printable keys, or a named string (`"Enter"` / `"Tab"` /
  `"ArrowLeft"` / `" "` for Space) for non-printable ones. Use this for
  "what character did the user type".
- `code` — layout-independent physical key code keyed by US QWERTY position
  (`"KeyA"` / `"Digit1"` / `"Space"` / `"Enter"` / `"ArrowLeft"` /
  `"Numpad0"` / `"ShiftLeft"`). On Dvorak / AZERTY the same physical
  position still reports `"KeyA"`, while `key` reflects the layout's actual
  output. Use this for "which physical key was pressed".
- `altKey` / `ctrlKey` / `shiftKey` / `metaKey` — modifier booleans. macOS
  Option maps to `altKey`, Command maps to `metaKey`.
- `repeat` — true on auto-repeated keydowns past the OS repeat delay.
- `location` — `0` standard / `1` left modifier / `2` right modifier /
  `3` numpad. Redundant with `code` for numpad keys (those already start
  with `"Numpad"`); prefer `code` for detection. See
  [Numeric keypad keys](#numeric-keypad-keys) for the handling contract.
- `isComposing` — same as the read-only context field above.
- `getModifierState(key)` — query individual states (`"Shift"`, `"Control"`,
  `"Alt"`, `"Meta"`, `"CapsLock"`). Other web-spec strings (`"Fn"` /
  `"NumLock"` / `"AltGraph"` / etc.) return `false` — macOS either lacks
  the key or can't report it faithfully.
- `keyIgnoringModifiers` *(host extension, not in the web spec)* — the
  layout-aware character with Option / Command / Control stripped (Shift
  preserved). Useful on macOS where Option doubles as a dead-key modifier
  and rewrites `key`: Option+(Dvorak p position) gives `keyIgnoringModifiers
  === "p"` even though `key === "π"`.

`ConfirmEvent` additionally has `candidate`, `absoluteIndex`,
`annotation?`, and `payload?` (the last two round-tripped from the original
`Candidate`).

`event.absoluteIndex` is the index into the full candidate list emitted
by the most recent `updateCandidates`. It is `-1` when no candidate is
active (a commit fired while `initialHighlight: -1` was in effect, or an
engine-driven `commit()`). This is **distinct** from the page-relative
index taken by `commitCandidateAtIndex(_)`. Example with `pageSize: 5`,
user on page 1 confirms the 2nd visible item:

```js
// inside handleKey
event.commitCandidateAtIndex(1);     // page-relative (0..pageSize-1)
// later, inside candidateConfirmed
event.absoluteIndex === 6;           // into the full list
```

### Character indices

`EmphasisRange`, `MarkedTextOptions.cursor`, and
`CandidateUpdateOptions.anchorAt` count **extended grapheme clusters**, not
UTF-16 code units. Use `Intl.Segmenter` to get aligned counts:

```js
const seg = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const characterCount = [...seg.segment(markedText)].length;
```

### Runtime globals

The host injects `console`, `manifest`, `navigator`, `localStorage`,
and `fetch` into the engine's global scope.

No `require`, `process`, `setTimeout`, or network APIs are exposed.
Engines run inside JavaScriptCore. `fetch` is a read-only file API
for engine-folder resources, not network access.

#### Global events

Host-emitted events (`storage`, `settingschange`, `languagechange`,
`fontcoveragechange`) follow DOM conventions on `globalThis`:

```js
addEventListener(type, callback, options?);
removeEventListener(type, callback);

// Object form: `this` binds to the listener object on dispatch.
addEventListener('storage', {
  handleEvent(event) { /* ... */ }
});
```

- `callback` may be a function or an object with a `handleEvent(event)`
  method. `handleEvent` is read at dispatch time, so reassigning it
  after registration is honored on the next event.
- `options` accepts `{ once: true }`. Other keys (`capture`, `signal`,
  `passive`, ...) log a warning and are ignored.
- Unknown event types are accepted silently (per DOM spec) — the
  listener simply never fires.
- `removeEventListener` takes the same `callback` reference used to
  register. `once`-registered listeners work the same way.

Per-event payload and dispatch semantics live in each event's own
subsection below.

#### `console`

Levels map to OSLog:

```
console.log   / console.info  → OSLog .info
console.trace                 → OSLog .info     (with stack)
console.debug                 → OSLog .debug
console.warn                  → OSLog .notice   (with stack)
console.error                 → OSLog .error    (with stack)
```

Uncaught exceptions also appear in the log with a stack trace.

View engine logs:

- **Console.app**: filter `subsystem:net.lukechang.inputmethod.MacishType category:JavaScript`
- **Terminal**: `log stream --predicate 'subsystem == "net.lukechang.inputmethod.MacishType" AND category == "JavaScript"' --level debug --style compact`
- **In this repo**: `make log-js` wraps the terminal command.

#### `manifest`

Engine-wide info injected by the host.

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
addEventListener('settingschange', applyConfig);
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

##### `manifest.modules`

Frozen, read-only views (each exposing `query(key)`) for the modules enabled
via the manifest [`modules`](#modules-optional) field — see there for the
available modules, their data, and the runtime API. Injected before module
evaluation (top-level reads and destructuring work).

##### `manifest.settings`

Read-only snapshot of the user's current settings, keyed by the manifest
`key`. Values match the field's declared schema after host sanitize —
a `toggle` field's value is always a boolean, etc.

```js
const showAssoc = manifest.settings.enableAssociatedMode;
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

##### Event: `settingschange`

Fired when `manifest.settings` content changes (deep-equal dirty check;
no spurious events). The callback receives `{ type: 'settingschange' }`
— read `manifest.settings` for the current values.

Attach at module scope, not on an instance — settings are engine-wide
and the listener registry only resets on engine reload (folder change,
file edit), so per-instance attach both confuses ownership and leaks
`this` across text-field sessions.

Most code should just read `manifest.settings` at the point of use:

```js
export default class MyEngine {
  handleKey(event) {
    if (manifest.settings.enableAssociatedMode) { ... }
  }
}
```

Attach a listener only when a settings change should trigger expensive
work — reloading a dictionary, rebuilding a trie, recompiling a regex:

```js
let dictionary = loadDictionary(manifest.settings.dictionaryPath);
addEventListener('settingschange', () => {
  dictionary = loadDictionary(manifest.settings.dictionaryPath);
});
```

##### `manifest.menu`

Live values of the manifest-declared [`menu`](#menu-optional) items,
keyed by item key (dividers carry no value). Read/write:

```js
manifest.menu.outputToSimplified;         // current value
manifest.menu.outputToSimplified = true;  // flip it
```

**Writes act immediately** — the very next commit reflects them — and
persist across sessions. This is the opposite of
`manifest.candidateWindow`'s next-activate semantics: menu values are
engine-global state shared with the IME menu's checkmarks, not
per-session configuration.

Keys are the declared items only. Reads of anything else return
`undefined`; writes to them (or non-boolean writes) are logged via OSLog
and silently ignored, same policy as `manifest.candidateWindow`.

##### Event: `menuchange`

Fired when the **user** flips a menu item from the IME menu. Read
`manifest.menu` for the new values. The engine's own writes to
`manifest.menu` do not fire it — engines never hear their own echo.

```js
addEventListener('menuchange', () => {
  applyMode(manifest.menu.strictMode);
});
```

#### `navigator`

Web-aligned host info and locale preferences.

| Property | Value |
|---|---|
| `navigator.language` | Most preferred language, BCP 47 (e.g. `"zh-TW"`). `""` if no preference. |
| `navigator.languages` | Frozen `ReadonlyArray<string>` of BCP 47 preferences, most preferred first. |
| `navigator.userAgent` | Static host identifier in the form `MacishType/{appVer} (macOS {osVer}) JavaScriptCore/{jscVer}`, e.g. `"MacishType/0.1.0 (macOS 26.5.0) JavaScriptCore/21624"`. Future engine ports may replace the trailing `JavaScriptCore/...` segment. |

Tags are web-style BCP 47 (lowercase language, uppercase region,
script dropped when redundant). Each region-tagged entry is followed
by its base form so first-match lookups get a natural fallback chain
— `[zh-TW, zh, en-US, en]`.

This reflects the user's preference, which may differ from the
language MacishType itself displays. Pick from your engine's own
translation table; don't assume MacishType ships matching translations.

Use `languages` to pick from your engine's own translation table:

```js
function applyL10n() {
  for (const lang of navigator.languages) {
    if (translations.has(lang)) { current = lang; return; }
  }
  current = 'en';
}
applyL10n();
addEventListener('languagechange', applyL10n);
```

##### Event: `languagechange`

Fired when the user's system language preferences change. The callback
receives `{ type: 'languagechange' }`; read `navigator.languages` for
the new list.

Deduplicated — unrelated locale changes (calendar / currency /
numbering system) don't fire this event.

##### Event: `fontcoveragechange`

Fired when the set of font-renderable characters changes (a font
installed or removed), if the engine enabled the `fontCoverage`
[module](#modules-optional). The callback receives
`{ type: 'fontcoveragechange' }`. `manifest.modules.fontCoverage`
already reflects the new coverage, so most engines (which query it live
per render) need not listen — attach only to invalidate caches derived
from coverage. Deduplicated: a font change that leaves coverage
identical doesn't fire.

#### `fetch(path)`

Reads a file from the engine folder. Web-aligned subset — read-only,
no network access.

```js
const dict = await fetch('./dict.json').then(r => r.json());
const text = await fetch('./templates/welcome.txt').then(r => r.text());
const blob = await fetch('./model.bin').then(r => r.arrayBuffer());
```

| Constraint | |
|---|---|
| Path | Either `./<relative>` (resolved from the engine folder root) or an absolute `engine:///<path>` URL string. Bare names, `file://` URLs, parent-escapes (`../`), query strings, and fragments all reject. |
| Body | `text()` / `json()` / `arrayBuffer()` — calling any one synchronously locks the body; a second body method call (including a second call to the same method) rejects immediately with `Error("Body has already been consumed")`. Recoverable failures (UTF-8 decode fail / read fail / ArrayBuffer alloc fail) un-lock so engines can fall back or retry. |
| Init arg | Declared `init?: unknown` for signature parity with the Web fetch API. Completely ignored at runtime; passing a non-undefined value emits `console.warn`. No headers / method / body / streams / abort. |
| Threading | `fetch()` returns once a background stat confirms the file is readable — disk reads run inside the body methods, off the main thread. |
| Hot-reload | Fetched files are watched alongside imports — modifying one outside the engine triggers a full module reload. See example below for the recommended pattern. |
| Errors | `fetch()` rejects on invalid path / missing file / non-regular file. `text()` / `json()` reject on non-UTF-8 body or malformed JSON. `arrayBuffer()` rejects on read failure or ArrayBuffer construction failure. |

The TypeScript return type is named `FetchResponse` (not `Response`)
to avoid colliding with the full DOM `Response` interface in
`lib.dom.d.ts`, which has many fields this host doesn't implement.

```js
// Module top-level — kicks off at engine load. Editing dict.json
// from outside triggers a module reload, so this fetch re-runs and
// `dict` is repopulated with the new file content automatically.
let dict = {};
fetch('./dict.json')
  .then(r => r.json())
  .then(d => { dict = d; })
  .catch(err => console.error('dict load failed:', err.message));

export default class MyEngine {
  handleKey(event) {
    // `dict` is shared across every text-field session via closure.
    // Until the fetch resolves it stays empty; handle as best-effort.
  }
}
```

Top-level `await` is not supported — module load faults. Use `.then(...)` as shown.

##### Module-relative paths

`./<relative>` resolves from the **engine folder root** — the same regardless
of which module calls `fetch()`. If a module nested in a subfolder wants to
fetch a sibling file, derive the absolute URL from `import.meta.url`:

```js
// In foo/B.js (import.meta.url = "engine:///foo/B.js")
const baseURL = import.meta.url.slice(0, import.meta.url.lastIndexOf('/') + 1);
const sibling = await fetch(baseURL + 'sibling.txt').then(r => r.text());
// Fetches engine:///foo/sibling.txt
```

`import.meta.url` is a synthetic `engine:///<path>` URL — it doesn't leak the
user's filesystem location, and `Response.url` follows the same scheme.

#### Module import resolution

`import` statements resolve relative to the importing module's URL (standard
ES module semantics):

| In `foo/B.js`, `import` of... | Resolves to |
|---|---|
| `'./sibling.js'` | `engine:///foo/sibling.js` |
| `'../shared.js'` | `engine:///shared.js` |
| `'/util.js'` | `engine:///util.js` (engine folder root) |
| `'util'` (bare specifier) | Rejected — no import map support |

`import 'X.js'` without `./` / `../` / `/` is a bare specifier — not supported.

#### `localStorage`

Per-engine, file-backed persistence with the Web Storage `Storage`
interface. Data survives engine reload and app restart.

```js
localStorage.setItem('lastUsed', JSON.stringify({ ts: Date.now() }));
const last = JSON.parse(localStorage.getItem('lastUsed') ?? 'null');
```

Data lives in `<engineFolder>/_storage/`, one file per key. Files are
named by percent-encoding the key (so `cache.v1` → `cache%2Ev1`),
with a `localStorage_` prefix to leave room for future storage kinds.

The `_storage/` folder is the engine's private data area: file changes
inside it never trigger engine reload. **Don't put engine source code
there** — edits won't hot-reload.

**API** (subset of Web Storage `Storage`):

| Member | Behavior |
|---|---|
| `localStorage.getItem(key)` | Returns the stored string, or `null` if missing. |
| `localStorage.setItem(key, value)` | Stores value. Both args coerced to string. |
| `localStorage.removeItem(key)` | Removes if present; no-op otherwise. |
| `localStorage.clear()` | Removes every key in this engine's storage. |
| `localStorage.length` | Current key count. |
| `localStorage.key(index)` | The i-th key, sorted alphabetically. `null` if out of range. |

The following are **programmer errors** and throw:

- Empty key (`""`).
- Encoded filename exceeds 200 bytes (raw key + UTF-8 expansion).
- Value exceeds 10 MB.

```js
try {
  localStorage.setItem('', 'x');  // throws: empty key
} catch (e) { console.error(e); }
```

**Filesystem errors** (permission denied, disk full, etc.) are logged
via OSLog and **silently swallowed**:

- `getItem` returns `null` on read failure.
- `setItem` / `removeItem` / `clear` drop the operation.

Engine code can call localStorage freely without try/catch around
environmental failures; only argument errors need handling.

**Property access is not supported.** Use the methods:

```js
localStorage.foo = 'bar';   // does NOT persist (frozen object)
const x = localStorage.foo; // undefined
```

**Lifecycle**: data persists until `removeItem` / `clear`, or until
the storage folder is deleted out-of-band. If the user re-picks the
same engine folder later, the previous `_storage/` is reused — values
written before survive folder re-pick. Picking a different folder
naturally points to that folder's own `_storage/` (empty unless
previously written into).

##### Event: `storage`

Fired when `_storage/` files are modified **outside** this engine —
typically the user editing them in Finder or via the shell. The
engine's own `setItem` / `removeItem` / `clear` do **not** trigger
it (matches the Web Storage spec: storage events fire in *other*
contexts).

```js
addEventListener('storage', (event) => {
  if (event.key === 'config') {
    reloadConfig(event.newValue);
  }
});
```

**Event shape**:

| Field | Value |
|---|---|
| `type` | `'storage'` |
| `key` | The localStorage key whose value changed. |
| `oldValue` | Always `null` (host doesn't cache prior values). |
| `newValue` | Current value, or `null` if the file was deleted. **Lazy** — disk is only read when a listener actually accesses `event.newValue`, then frozen for further reads. |
| `storageArea` | The `localStorage` object. |

**External `clear` not modeled.** When the user deletes the whole
`_storage/` folder, FSEvents reports per-file deletions and a
separate event fires for each key — not a single Web-style
`key === null` clear event.

**Lazy `newValue` edge case**: all listeners on one dispatch share
the same `event` object. If a listener mutates storage (e.g.
`localStorage.setItem(key, "X")`) before `event.newValue` has been
read for the first time, the eventual first read sees the
post-mutation value rather than the value that originally triggered
the event. Read `newValue` early if precise "value-at-event-time"
matters.

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

Interfaces only describe the **instance** side of a class. Static members
(like `reverseLookup`, see the `capabilities` section) live on the class
object itself, typed separately by `InputEngineConstructor`. TypeScript
engines check both sides with `implements` + `satisfies`:

```ts
import type { InputEngine, InputEngineConstructor, KeyEvent } from "../Utils/MacishType";

class MyEngine implements InputEngine {
  handleKey(event: KeyEvent): boolean | void { /* … */ }

  static reverseLookup(character: string): string[] { /* … */ }
}

export default MyEngine satisfies InputEngineConstructor;
```

`satisfies` validates the exported class value against the constructor
interface (statics included) without widening its inferred type; a plain
`implements` alone never checks statics.

The JSDoc equivalent for plain JS engines (editors running TypeScript 5.0+
with `// @ts-check` or `checkJs`):

```js
/** @typedef {import("../Utils/MacishType").InputEngine} InputEngine */
/** @typedef {import("../Utils/MacishType").InputEngineConstructor} InputEngineConstructor */

/** @implements {InputEngine} */
class MyEngine {
  /**
   * @param {string} character
   * @returns {(string | {code: string, annotation?: string})[]}
   */
  static reverseLookup(character) { /* … */ }
}

export default /** @satisfies {InputEngineConstructor} */ (MyEngine);
```

