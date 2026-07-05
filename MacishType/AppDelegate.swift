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

    static func main() {
        // Inside the App Sandbox, JSC's default signal-based VM traps
        // cannot interrupt JIT'd code, leaving the JS watchdog unable
        // to stop runaway loops. Polling traps embed the check in the
        // code instead; must be set before JSC first reads its options.
        setenv("JSC_usePollingTraps", "1", 1)
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }

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

        InputEngine.observeEnabledEngines()

        // Warm the font-coverage union off-main so the first query doesn't stall.
        FontCoverage.shared.preheat()

        setupMainMenu()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit MacishType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
