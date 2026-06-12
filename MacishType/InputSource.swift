import Carbon.HIToolbox
import Foundation

/// Typed accessors for Text Input Source properties (Carbon hands them back as
/// opaque pointers).
extension TISInputSource {
    func string(_ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(self, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    func bool(_ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(self, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }

    func strings(_ key: CFString) -> [String]? {
        guard let pointer = TISGetInputSourceProperty(self, key) else { return nil }
        return Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
    }
}

/// An installed ASCII-capable keyboard layout, for the layout-override picker.
struct KeyboardLayout: Identifiable, Hashable {
    let id: String        // TISInputSourceID, e.g. "com.apple.keylayout.Dvorak"
    let name: String      // OS-localized display name
    let language: String  // primary language code, e.g. "en" ("" if none)
}

enum KeyboardLayouts {
    /// UserDefaults key for the pinned layout's `TISInputSourceID`; empty string
    /// means follow the system's last-used Roman layout (no override).
    static let overrideDefaultsKey = "keyboardLayoutOverride"

    /// Every installed (not just enabled) ASCII-capable keyboard layout, for the
    /// layout-override picker.
    static func asciiCapable() -> [KeyboardLayout] {
        guard let sources = TISCreateInputSourceList(nil, true)?
            .takeRetainedValue() as? [TISInputSource] else { return [] }
        return sources.compactMap { source in
            guard source.string(kTISPropertyInputSourceType) == (kTISTypeKeyboardLayout as String),
                  source.bool(kTISPropertyInputSourceIsASCIICapable),
                  let id = source.string(kTISPropertyInputSourceID),
                  let name = source.string(kTISPropertyLocalizedName) else { return nil }
            return KeyboardLayout(
                id: id, name: name,
                language: source.strings(kTISPropertyInputSourceLanguages)?.first ?? "")
        }
    }
}
