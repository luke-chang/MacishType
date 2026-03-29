import Cocoa
import InputMethodKit
import OSLog

// Sets up the app delegate manually since there is no MainMenu.nib.
class App: NSApplication {
    private let appDelegate = AppDelegate()

    override init() {
        super.init()
        self.delegate = appDelegate
    }

    // Required by NSCoding (via NSResponder), but unused since the app has no nib.
    required init?(coder: NSCoder) {
        fatalError("This app does not use nib-based initialization")
    }
}

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Connect to the input method server
        let info = Bundle.main.infoDictionary
        server = IMKServer(
            name: info?["InputMethodConnectionName"] as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )

        // Log version info
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let hash = info?["GitCommitHash"] as? String ?? "?"
        #if DEBUG
        Logger.app.info("Started (debug:v\(version, privacy: .public):\(build, privacy: .public):\(hash, privacy: .public))")
        #else
        Logger.app.info("Started (v\(version, privacy: .public):\(build, privacy: .public):\(hash, privacy: .public))")
        #endif

        // Initialize shared resources
        currentEngine = ExampleEngine.shared
        _ = ThemeManager.shared
    }
}
