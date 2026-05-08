# MacishType

A macOS input method built with InputMethodKit, aiming to replicate the look and feel of the built-in macOS input methods.

## Environment

- Swift 5
- Xcode 26.3+
- macOS 14.0+ (deployment target)

## Development

Build Debug version:

```bash
make build
```

Build Debug, deploy, and reload in one step:

```bash
make debug
```

Then go to **System Settings > Keyboard > Input Sources** to add the input method.

Other useful commands:

```bash
make reload              # Force restart input method by killing its process
make release             # Build Release version (current architecture)
make release-universal   # Build Release version (universal binary)
make install             # Build Release, deploy, and reload
make uninstall           # Remove installed input method
make clean               # Clean build artifacts
make log                 # Stream live OSLog output
make log-history         # Show recent log history (default 1h, use LOG_SHOW_LAST=24h to override)
make preview             # Build and run CandidateWindow preview app
```

## Project Structure

```
MacishType/
├── MacishType/                       # Input method app
│   ├── AppDelegate.swift             # App lifecycle and IMKServer setup
│   ├── InputController.swift         # IMKInputController subclass, key event routing
│   ├── InputEngine.swift             # Base input engine with shared key handling logic
│   ├── ExampleEngine/                # Reverse-lookup demo engine
│   ├── JavaScriptEngine/             # ES module bridge for JS-implemented engines
│   ├── CandidateWindow.swift         # Candidate window public API and shared types
│   ├── MacishCandidateWindow/        # Candidate window panels (horizontal / vertical / expandable)
│   ├── ThemeManager.swift            # Per-app accent color caching and theme events
│   ├── WindowManager.swift           # Singleton manager for non-candidate windows
│   ├── SettingsWindow.swift          # Settings window (AppKit shell + SwiftUI panes)
│   ├── AboutView.swift               # About window (SwiftUI)
│   ├── SecurityScopedBookmark.swift  # Sandbox-friendly persisted folder/file picker
│   ├── Logger.swift                  # OSLog logger extensions
│   ├── Info.plist                    # App configuration and input mode declarations
│   ├── InfoPlist.xcstrings           # Info.plist localization (en, zh-Hant)
│   ├── Localizable.xcstrings         # UI string localization (en, zh-Hant)
│   ├── App.entitlements              # Sandbox and entitlements
│   └── Resources/                    # App-level assets (app icon, default menu icon)
├── Engines/                          # Reference JS engine sources (loadable via JSExternal picker)
├── CandidateWindowPreview/           # Standalone preview app for the candidate window
├── Scripts/                          # Helper scripts (icon generator, etc.)
├── MacishType.xcodeproj/             # Xcode project file
├── Makefile                          # Build, install, and dev commands
└── README.md
```
