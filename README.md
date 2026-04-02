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
make reload                # Force restart input method by killing its process
make release               # Build Release version (current architecture)
make release-universal     # Build Release version (universal binary)
make install               # Build Release, deploy, and reload
make uninstall             # Remove installed input method
make clean                 # Clean build artifacts
make log                   # Stream live OSLog output
make log-history           # Show recent log history (default 1h, use LOG_SHOW_LAST=24h to override)
make candidate-window-test # Build and run standalone CandidateWindow test app
```
