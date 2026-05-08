import OSLog

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier!

    static let app = Logger(subsystem: subsystem, category: "App")
    static let windowManager = Logger(subsystem: subsystem, category: "WindowManager")
    static let themeManager = Logger(subsystem: subsystem, category: "ThemeManager")
    static let inputController = Logger(subsystem: subsystem, category: "InputController")
    static let inputEngine = Logger(subsystem: subsystem, category: "InputEngine")
    static let javaScriptEngine = Logger(subsystem: subsystem, category: "JavaScriptEngine")
    static let securityScopedBookmark = Logger(subsystem: subsystem, category: "SecurityScopedBookmark")
}
