import Carbon.HIToolbox
import Foundation

/// Named `NSEvent.keyCode` values (sourced from Carbon's `kVK_*` constants), so
/// key handling reads without magic numbers.
enum KeyCode {
    static let `return` = UInt16(kVK_Return)
    static let tab = UInt16(kVK_Tab)
    static let space = UInt16(kVK_Space)
    static let backspace = UInt16(kVK_Delete)   // the Delete/Backspace key
    static let escape = UInt16(kVK_Escape)
    static let keypadEnter = UInt16(kVK_ANSI_KeypadEnter)
    static let keypadClear = UInt16(kVK_ANSI_KeypadClear)

    static let equal = UInt16(kVK_ANSI_Equal)
    static let minus = UInt16(kVK_ANSI_Minus)
    static let leftBracket = UInt16(kVK_ANSI_LeftBracket)
    static let rightBracket = UInt16(kVK_ANSI_RightBracket)
    static let quote = UInt16(kVK_ANSI_Quote)

    static let home = UInt16(kVK_Home)
    static let pageUp = UInt16(kVK_PageUp)
    static let end = UInt16(kVK_End)
    static let pageDown = UInt16(kVK_PageDown)
    static let leftArrow = UInt16(kVK_LeftArrow)
    static let rightArrow = UInt16(kVK_RightArrow)
    static let downArrow = UInt16(kVK_DownArrow)
    static let upArrow = UInt16(kVK_UpArrow)
}

// Maps macOS virtual key codes (HIToolbox/Events.h) to W3C UI Events
// KeyboardEvent `code` / `key` / `location` values. Tables are derived from
// US QWERTY physical positions, so `code` is layout-independent — pressing
// the physical "A" position always yields "KeyA" regardless of the active
// input source. The `key` returned for named keys comes from this table;
// character keys fall through to NSEvent.characters via webKey()'s second
// tier.
enum KeyboardEventMapping {
    static func webCode(for keyCode: UInt16) -> String {
        macKeyCodeToWebCode[keyCode] ?? ""
    }

    /// Reverse lookup: web `code` string back to Mac virtual keyCode.
    /// nil for unknown codes (or `""`).
    static func keyCode(forWebCode code: String) -> UInt16? {
        webCodeToMacKeyCode[code]
    }

    /// Character-producing keys in the physical keypad cluster, derived from
    /// the web-code map: every "Numpad*" code except NumpadEnter (a named
    /// key; Clear is excluded by the data — its code is "NumLock"). The
    /// same rule JS engines apply as `code.startsWith("Numpad")`.
    static let numericPadCharacterKeys: Set<UInt16> = Set(
        macKeyCodeToWebCode
            .filter { $0.value.hasPrefix("Numpad") && $0.value != "NumpadEnter" }
            .keys
    )

    static func webKey(for keyCode: UInt16, characters: String?) -> String {
        if let namedKey = macKeyCodeToWebKey[keyCode] {
            return namedKey
        }
        if let characters, !characters.isEmpty {
            return characters
        }
        return "Unidentified"
    }

    static func location(for keyCode: UInt16) -> Int {
        macKeyCodeToLocation[keyCode] ?? 0
    }

    private static let macKeyCodeToWebCode: [UInt16: String] = [
        // Letters (kVK_ANSI_A..M, scattered per ADB layout)
        0: "KeyA", 1: "KeyS", 2: "KeyD", 3: "KeyF", 4: "KeyH",
        5: "KeyG", 6: "KeyZ", 7: "KeyX", 8: "KeyC", 9: "KeyV",
        11: "KeyB", 12: "KeyQ", 13: "KeyW", 14: "KeyE", 15: "KeyR",
        16: "KeyY", 17: "KeyT",
        31: "KeyO", 32: "KeyU", 34: "KeyI", 35: "KeyP",
        37: "KeyL", 38: "KeyJ", 40: "KeyK",
        45: "KeyN", 46: "KeyM",

        // Digits
        18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4",
        22: "Digit6", 23: "Digit5", 25: "Digit9", 26: "Digit7",
        28: "Digit8", 29: "Digit0",

        // Symbols on main row
        24: "Equal", 27: "Minus", 30: "BracketRight", 33: "BracketLeft",
        39: "Quote", 41: "Semicolon", 42: "Backslash", 43: "Comma",
        44: "Slash", 47: "Period", 50: "Backquote",

        // Action keys
        36: "Enter", 48: "Tab", 49: "Space", 51: "Backspace",
        53: "Escape", 117: "Delete",

        // Modifier keys (left / right pairs)
        54: "MetaRight", 55: "MetaLeft",
        56: "ShiftLeft", 60: "ShiftRight",
        57: "CapsLock",
        58: "AltLeft", 61: "AltRight",
        59: "ControlLeft", 62: "ControlRight",
        63: "Fn",

        // Arrows
        123: "ArrowLeft", 124: "ArrowRight",
        125: "ArrowDown", 126: "ArrowUp",

        // Navigation cluster
        115: "Home", 116: "PageUp", 119: "End", 121: "PageDown",
        114: "Help",

        // F-keys
        96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13",
        106: "F16", 107: "F14", 109: "F10", 111: "F12",
        113: "F15", 118: "F4", 120: "F2", 122: "F1",
        64: "F17", 79: "F18", 80: "F19", 90: "F20",

        // Numpad. W3C uses dedicated "Numpad*" codes — never "Digit*" + location.
        // Special: kVK_ANSI_KeypadClear (71) maps to "NumLock" per W3C spec
        // (Mac's physical Clear key sits where NumLock lives on PC keyboards).
        65: "NumpadDecimal", 67: "NumpadMultiply", 69: "NumpadAdd",
        71: "NumLock",
        75: "NumpadDivide", 76: "NumpadEnter", 78: "NumpadSubtract",
        81: "NumpadEqual",
        82: "Numpad0", 83: "Numpad1", 84: "Numpad2", 85: "Numpad3",
        86: "Numpad4", 87: "Numpad5", 88: "Numpad6", 89: "Numpad7",
        91: "Numpad8", 92: "Numpad9", 95: "NumpadComma",

        // Audio (some Mac keyboards)
        72: "AudioVolumeUp", 73: "AudioVolumeDown", 74: "AudioVolumeMute",

        // ISO / JIS layout-specific physical keys
        10: "IntlBackslash",
        93: "IntlYen", 94: "IntlRo",
        102: "Lang2", 104: "Lang1",
    ]

    private static let webCodeToMacKeyCode: [String: UInt16] = {
        Dictionary(uniqueKeysWithValues: macKeyCodeToWebCode.map { ($0.value, $0.key) })
    }()

    // Named-key key values. Character keys (letters / digits / symbols) and
    // numpad digit / operator keys aren't here — webKey() falls through to
    // the `characters` argument, which carries NSEvent.characters already
    // reflecting layout + shift + caps lock.
    private static let macKeyCodeToWebKey: [UInt16: String] = [
        36: "Enter",
        48: "Tab",
        49: " ",
        51: "Backspace",
        53: "Escape",
        117: "Delete",

        // Arrows
        123: "ArrowLeft", 124: "ArrowRight",
        125: "ArrowDown", 126: "ArrowUp",

        // Navigation cluster
        115: "Home", 116: "PageUp", 119: "End", 121: "PageDown",
        114: "Help",

        // Modifier keys (rarely fire as keyDown; usually .flagsChanged)
        54: "Meta", 55: "Meta",
        56: "Shift", 60: "Shift",
        57: "CapsLock",
        58: "Alt", 61: "Alt",
        59: "Control", 62: "Control",
        63: "Fn",

        // F-keys
        96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13",
        106: "F16", 107: "F14", 109: "F10", 111: "F12",
        113: "F15", 118: "F4", 120: "F2", 122: "F1",
        64: "F17", 79: "F18", 80: "F19", 90: "F20",

        // Numpad named keys. Keypad Clear's key value is "Clear" even though
        // its code is "NumLock"; NumpadEnter shares "Enter" with the main row.
        71: "Clear",
        76: "Enter",

        // Audio
        72: "AudioVolumeUp", 73: "AudioVolumeDown", 74: "AudioVolumeMute",
    ]

    private static let macKeyCodeToLocation: [UInt16: Int] = [
        // Left side modifier keys
        55: 1, 56: 1, 58: 1, 59: 1,

        // Right side modifier keys
        54: 2, 60: 2, 61: 2, 62: 2,

        // Numpad — includes Clear (71), Enter (76), and the operators because
        // they live physically in the numpad cluster regardless of W3C code.
        65: 3, 67: 3, 69: 3, 71: 3, 75: 3, 76: 3, 78: 3, 81: 3,
        82: 3, 83: 3, 84: 3, 85: 3, 86: 3, 87: 3, 88: 3, 89: 3,
        91: 3, 92: 3, 95: 3,
    ]
}
