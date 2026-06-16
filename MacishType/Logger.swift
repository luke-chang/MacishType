import OSLog

// `nonisolated` so loggers are callable from Decodable inits, FSEvents
// callbacks, and other nonisolated contexts.
extension Logger {
    nonisolated private static let subsystem = Bundle.main.bundleIdentifier!

    nonisolated static let app = Logger(subsystem: subsystem, category: "App")
    nonisolated static let windowManager = Logger(subsystem: subsystem, category: "WindowManager")
    nonisolated static let themeManager = Logger(subsystem: subsystem, category: "ThemeManager")
    nonisolated static let inputController = Logger(subsystem: subsystem, category: "InputController")
    nonisolated static let inputEngine = Logger(subsystem: subsystem, category: "InputEngine")
    nonisolated static let associatedDictionary = Logger(subsystem: subsystem, category: "AssociatedDictionary")
    nonisolated static let wordFrequency = Logger(subsystem: subsystem, category: "WordFrequency")
    nonisolated static let symbolName = Logger(subsystem: subsystem, category: "SymbolName")
    nonisolated static let javaScriptEngine = Logger(subsystem: subsystem, category: "JavaScriptEngine")
    /// JS-originated logs (engine `console.*`, uncaught exceptions, rejections),
    /// separate from `javaScriptEngine` so users can filter engine runtime
    /// errors without the Swift bridge noise.
    nonisolated static let javaScript = Logger(subsystem: subsystem, category: "JavaScript")
    nonisolated static let securityScopedBookmark = Logger(subsystem: subsystem, category: "SecurityScopedBookmark")
    nonisolated static let fontCoverage = Logger(subsystem: subsystem, category: "FontCoverage")
}
