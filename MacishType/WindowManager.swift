import Cocoa
import SwiftUI
import OSLog

@MainActor
class WindowManager {
    static let shared = WindowManager()

    enum Identifier: String {
        case about
        case settings
    }

    private var windows: [Identifier: NSWindow] = [:]
    private var closeObservers: [Identifier: any NSObjectProtocol] = [:]

    private init() {}

    func showWindow<Content: View>(
        _ id: Identifier,
        title: String,
        asPanel: Bool = false,
        transparentTitlebar: Bool = false,
        content: @escaping () -> Content
    ) {
        // Activate before showing the window. For LSUIElement input methods,
        // the host app reclaims focus after the IMKit menu dismisses. Calling
        // activate early wins the race so the window receives focus reliably.
        // ignoringOtherApps is required despite being documented as no-op on
        // macOS 14+; without it the window fails to gain focus.
        NSApp.activate(ignoringOtherApps: true)

        if let existing = windows[id], existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            Logger.windowManager.info("Brought \(id.rawValue, privacy: .public) window to front")
            return
        }

        let controller = NSHostingController(rootView: content())
        let window: NSWindow = asPanel
            ? NSPanel(contentViewController: controller)
            : NSWindow(contentViewController: controller)
        window.title = title
        if transparentTitlebar {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.isMovableByWindowBackground = true
        } else {
            window.styleMask = [.titled, .closable]
        }
        window.isReleasedWhenClosed = false
        if let panel = window as? NSPanel {
            panel.hidesOnDeactivate = false
        }

        window.setContentSize(controller.view.fittingSize)
        centerOnMouseScreen(window)

        if let observer = closeObservers[id] { NotificationCenter.default.removeObserver(observer) }
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.closeObservers.removeValue(forKey: id) {
                    NotificationCenter.default.removeObserver(observer)
                }
                self.windows.removeValue(forKey: id)
                Logger.windowManager.info("Closed \(id.rawValue, privacy: .public) window")
            }
        }

        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        Logger.windowManager.info("Opened \(id.rawValue, privacy: .public) window")
    }

    func close(_ id: Identifier) {
        windows[id]?.close()
    }

    private func centerOnMouseScreen(_ window: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let windowSize = window.frame.size
        let x = visibleFrame.midX - windowSize.width / 2
        let y = visibleFrame.midY - windowSize.height / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

extension WindowManager {
    func openAbout() {
        showWindow(.about, title: "MacishType", asPanel: true, transparentTitlebar: true) {
            AboutView()
        }
    }

    func openSettings() {
        showWindow(.settings, title: String(localized: "MacishType Settings")) {
            SettingsView()
        }
    }
}
