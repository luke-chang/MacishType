import Carbon.HIToolbox

/// Named `NSEvent.keyCode` values (sourced from Carbon's `kVK_*` constants), so
/// key handling reads without magic numbers.
enum KeyCode {
    static let `return` = UInt16(kVK_Return)
    static let tab = UInt16(kVK_Tab)
    static let space = UInt16(kVK_Space)
    static let backspace = UInt16(kVK_Delete)   // the Delete/Backspace key
    static let escape = UInt16(kVK_Escape)

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
