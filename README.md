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
├── MacishType/                                    # Main input method app
│   ├── AppDelegate.swift                          # App lifecycle and IMKServer setup
│   ├── InputController.swift                      # IMKInputController subclass, key event routing
│   ├── InputEngine.swift                          # Base input engine with shared key handling logic
│   ├── ExampleEngine/                             # Example input engine implementation
│   │   ├── ExampleEngine.swift                    # Reverse-lookup demo engine
│   │   └── Resources/                             # ExampleEngine assets
│   │       └── ExampleMenuIcon.tiff               # Menu bar icon for ExampleEngine
│   ├── CandidateWindow.swift                      # Candidate window public API and shared types
│   ├── SequoiaCandidateWindow/                    # macOS Sequoia style candidate window
│   │   ├── SequoiaCandidateWindow.swift           # Style controller (panel switching)
│   │   ├── SequoiaBasePanel.swift                 # NSPanel base (vibrancy, positioning, theming)
│   │   ├── SequoiaHorizontalBasePanel.swift       # Shared horizontal panel base
│   │   ├── SequoiaHorizontalExpandablePanel.swift # Expandable layout with grid expand/collapse
│   │   ├── SequoiaHorizontalSimplePanel.swift     # Non-expandable layout with page navigation
│   │   ├── SequoiaVerticalPanel.swift             # Vertical scrolling layout
│   │   ├── SequoiaCandidateItemView.swift         # Single candidate cell with index and label
│   │   ├── SequoiaChevronView.swift               # Expand/collapse toggle button
│   │   ├── SequoiaPageArrowView.swift             # Page up/down arrow control
│   │   ├── SequoiaHighlightView.swift             # Selected row background for expanded mode
│   │   └── SequoiaSeparatorView.swift             # Horizontal separator between candidate rows
│   ├── ThemeManager.swift                         # Per-app accent color caching and theme events
│   ├── WindowManager.swift                        # Singleton manager for non-candidate windows
│   ├── SettingsView.swift                         # Settings window (SwiftUI)
│   ├── AboutView.swift                            # About window (SwiftUI)
│   ├── Logger.swift                               # OSLog logger extensions
│   ├── Info.plist                                 # App configuration and input mode declarations
│   ├── InfoPlist.xcstrings                        # Info.plist localization (en, zh-Hant)
│   ├── Localizable.xcstrings                      # UI string localization (en, zh-Hant)
│   ├── App.entitlements                           # Sandbox and entitlements
│   └── Resources/                                 # App-level assets
│       ├── AppIcon.icns                           # Application icon
│       └── MenuIcon.tiff                          # Default menu bar icon
├── CandidateWindowPreview/                        # Standalone preview app for CandidateWindow
│   └── CandidateWindowPreview.swift               # Preview app with editable candidate list
├── Scripts/                                       # Helper scripts
│   └── GenerateIcon.swift                         # Menu bar icon generator (renders text into TIFF)
├── Makefile                                       # Build, install, and dev commands
└── README.md
```
