# MacishType

A macOS input method that replicates the system look and feel, extensible via external JavaScript engines.

## Highlights

- Native-looking candidate window — horizontal / vertical / expandable layouts, with accent color matching the foreground app
- Write engines in JavaScript — hot-reloaded from a picked folder, with a native Settings UI auto-generated from `manifest.json`

## Environment

### Runtime

- macOS 14.0 or later

### Development

- Xcode 26.3 or later
- Swift 5.0
- macOS 14.0+ SDK

## Installation

Requires Xcode (used by `make install` to build the Release binary).

### First install

1. `make install`
   - Builds Release, copies the app to `~/Library/Input Methods/`, and kills any running input method process.
2. **Log out and back in.**
   - On first install, MacishType won't show up in the input source picker until you log back in.
3. Open **System Settings → Keyboard → Input Sources → +** and pick the input sources you want from the MacishType section.

### Upgrade

1. `make install`
   - The Makefile removes the old version, kills the running process, and installs the new one.
2. **Log out and back in** *(only if needed).*
   - Updates usually take effect immediately. But if a change doesn't seem to apply — or a newly added input source doesn't show up in the picker — logging out and back in is worth trying.

### Uninstall

1. `make uninstall`
   - Removes the app, Application Scripts, and the user container's `Data/` directory.
2. **Log out and back in.**
   - Required for MacishType to fully unregister from System Settings.

## Development

### First-time setup

Same as the [Installation](#installation) flow above, but use `make debug` instead of `make install` to deploy a Debug build.

### Iteration loop

After a code change:

- `make debug` — rebuild and reinstall in one step.
- `make log` — stream live OSLog output from the input method.
- `make log-js` — stream JS-originated logs (engine `console.*`, uncaught exceptions, rejections).
- `make log-history` — show recent log history (default 1h; override with `LOG_SHOW_LAST=24h`).
- `make preview` — build and run the CandidateWindow preview app, for iterating on the candidate window UI without running the full IM.

### Other targets

- `make build` — build Debug without installing.
- `make release` / `make release-universal` — build Release (current architecture or universal binary).
- `make clean` — clean build artifacts.
- `make reload` — restart the input method without rebuilding (e.g. after editing installed bundle resources in place).

## Writing an engine

### External JavaScript engine

A MacishType JavaScript engine is a folder with `manifest.json` and an entry module (e.g. `index.js`). Load it from MacishType's own **Settings → JS → Engine folder → Choose Folder…**; the host watches the folder with FSEvents and reloads on edit, so iterating doesn't require restarting the input method.

Start here:

- [`Engines/README.md`](Engines/README.md) — full engine-writing guide (manifest, lifecycle, event mutators, Settings schema, runtime globals)
- [`Engines/ExampleEngine/`](Engines/ExampleEngine/) — reference engine to copy and edit
- [`Engines/Utils/MacishType.d.ts`](Engines/Utils/MacishType.d.ts) — TypeScript definitions for IDE autocomplete, type checking, and bundler integration

### Bundled Swift engine

Subclass [`InputEngine`](MacishType/InputEngine.swift), override `engineID` and `handleKey`, and register the subclass in the static `InputEngine.engines` dictionary keyed by its `engineID`. Then declare the matching input source in [`MacishType/Info.plist`](MacishType/Info.plist) under `ComponentInputModeDict` (replace `YourEngineID` below):

```xml
<!-- under tsVisibleInputModeOrderedArrayKey -->
<string>net.lukechang.inputmethod.MacishType.YourEngineID</string>

<!-- under tsInputModeListKey -->
<key>net.lukechang.inputmethod.MacishType.YourEngineID</key>
<dict>
    <key>TISInputSourceID</key>
    <string>net.lukechang.inputmethod.MacishType.YourEngineID</string>
    <key>tsInputModeIsVisibleKey</key>
    <true/>
    <key>tsInputModeMenuIconFileKey</key>
    <string>YourEngineID/MenuIcon.tiff</string>
    <key>TISIconLabels</key>
    <dict>
        <key>Primary</key>
        <string>YourLabel</string>
    </dict>
    <!-- ... see the Example entry for additional keys -->
</dict>
```

**Engine resources** (icons, dictionaries, etc.) live in `MacishType/<engineID>Engine/Resources/` and are staged into `<bundle>/Resources/<engineID>/` at build time by the **Stage Engine Resources** run-script phase (the `Engine` suffix is stripped — e.g. `ExampleEngine/Resources/ExampleMenuIcon.tiff` → `Example/ExampleMenuIcon.tiff`). Because each engine's resources land in their own subfolder, file names don't need to be unique across engines.

> [!IMPORTANT]
> The source `Resources/` folder **must** be excluded from the default Copy Resources phase, otherwise resources end up in the bundle root and collide across engines. In Xcode, select the `Resources/` folder → File Inspector → **Build Rules** → switch *Apply to Each File* to **Apply Once to Folder**.

For menu and palette icons, [`Scripts/GenerateIcon.swift`](Scripts/GenerateIcon.swift) produces a system-style rounded-square TIFF with a character cut out — e.g. `swift Scripts/GenerateIcon.swift 例 ExampleEngine/Resources/ExampleMenuIcon`.

Reference: [`MacishType/ExampleEngine/`](MacishType/ExampleEngine/) — the bundled Swift engine, including associated-phrase mode, a Settings form, and the resources layout.

## Writing your own candidate window

The bundled [`MacishType/MacishCandidateWindow/`](MacishType/MacishCandidateWindow/) is one implementation of [`CandidateWindowImpl`](MacishType/CandidateWindow.swift), the abstract base that defines the override points (`apply`, `updateCandidates`, `show`, `hide`, `handleNavigation`, `commitSelectedCandidate`, etc.). To build a different candidate window, create a parallel folder under `MacishType/` with your own `CandidateWindowImpl` subclass and any supporting types, then add a `Style` case in [`CandidateWindow.swift`](MacishType/CandidateWindow.swift) and a matching arm in the `activeImpl` switch that constructs your subclass.

Shared types (`Candidate`, `CandidateWindowConfiguration`, `CandidateWindowDelegate`) live in `CandidateWindow.swift`.

## License

See [LICENSE](LICENSE).
