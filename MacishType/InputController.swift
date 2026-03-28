import Cocoa
import InputMethodKit

@objc(InputController)
class InputController: IMKInputController {
    private lazy var inputMethodMenu: NSMenu = {
        let menu = NSMenu()
        let aboutItem = NSMenuItem(
            title: String(localized: "About MacishType"),
            action: #selector(showAboutWindow(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)
        return menu
    }()

    override func menu() -> NSMenu! { inputMethodMenu }

    @MainActor @objc private func showAboutWindow(_ sender: Any?) {
        WindowManager.shared.openAbout()
    }
}
