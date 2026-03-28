import Cocoa
import InputMethodKit

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
        let info = Bundle.main.infoDictionary
        server = IMKServer(
            name: info?["InputMethodConnectionName"] as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }
}
