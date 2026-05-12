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
    nonisolated static let javaScriptEngine = Logger(subsystem: subsystem, category: "JavaScriptEngine")
    nonisolated static let securityScopedBookmark = Logger(subsystem: subsystem, category: "SecurityScopedBookmark")
}
