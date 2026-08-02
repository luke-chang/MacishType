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
        guard isInstalledCopy else {
            Logger.app.fault(
                "launched from \(Bundle.main.bundleURL.path, privacy: .public), which is not an Input Methods directory — exiting rather than competing with the installed copy"
            )
            exit(0)
        }

        // Connect to the input method server
        let info = Bundle.main.infoDictionary
        server = IMKServer(
            name: info?["InputMethodConnectionName"] as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        if server == nil {
            Logger.app.fault("IMKServer creation failed — this process receives no key events")
        }
        reportRivalInstances()

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

        // Before launch completes, so notification taps route from a cold start.
        NotificationManager.shared.registerDelegate()

        setupMainMenu()
    }

    /// An input method is only ever meant to run from an Input Methods directory.
    /// A build product carries the same bundle ID, so LaunchServices can resolve
    /// to it and start the wrong copy — which then fights the installed one for
    /// the single IMKServer connection name. Matching the parent directory name
    /// covers both ~/Library and /Library, and sidesteps the sandbox's
    /// `NSHomeDirectory()` pointing at the container rather than the real home.
    private var isInstalledCopy: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Input Methods"
    }

    /// Backstop for two copies in the install location itself (an install racing
    /// a still-dying process). Only one owns the IMKServer connection name; the
    /// loser looks healthy while receiving no key events, so name the rival.
    private func reportRivalInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where other.processIdentifier != mine {
            Logger.app.fault(
                "another instance is running (pid \(other.processIdentifier, privacy: .public)) from \(other.bundleURL?.path ?? "unknown", privacy: .public)"
            )
        }
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

        // Key equivalents (Cmd+V and friends) dispatch through the main menu
        // even though an LSUIElement app never shows a menu bar — without an
        // Edit menu, text fields in our windows can't cut/copy/paste.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
