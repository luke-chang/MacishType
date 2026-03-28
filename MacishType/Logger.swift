import OSLog

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier!

    static let app = Logger(subsystem: subsystem, category: "App")
    static let windowManager = Logger(subsystem: subsystem, category: "WindowManager")
}
