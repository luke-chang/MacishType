import AppKit
import OSLog
import UserNotifications

/// Shared wrapper around `UNUserNotificationCenter`: authorization, the
/// system-settings deep link, and posting. Feature notifiers build their own
/// content and enablement, then call `post`.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private override init() { super.init() }

    private let center = UNUserNotificationCenter.current()

    private nonisolated static let settingsEngineIDKey = "settingsEngineID"

    func registerDelegate() {
        center.delegate = self
    }

    /// Current authorization status, for the "notifications are off" hint when
    /// a feature is enabled but permission was denied.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Request permission if undecided; returns the resulting status. `await`
    /// suspends until the user answers, so the status reflects their choice.
    @discardableResult
    func requestAuthorization() async -> UNAuthorizationStatus {
        do {
            let granted = try await center.requestAuthorization(options: [.alert])
            if granted {
                Logger.notification.info("notification authorization granted")
            } else {
                Logger.notification.notice("notification authorization denied")
            }
        } catch {
            Logger.notification.error(
                "notification authorization request failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        return await center.notificationSettings().authorizationStatus
    }

    /// Post a notification, gated by current authorization (never requests it).
    /// Reusing an identifier replaces that notification instead of stacking.
    /// A non-nil `settingsEngineID` makes a tap open that engine's settings.
    func post(identifier: String, title: String, body: String, settingsEngineID: String? = nil) {
        Task {
            guard await authorizationStatus() == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let settingsEngineID {
                content.userInfo = [Self.settingsEngineIDKey: settingsEngineID]
            }
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            do {
                try await center.add(request)
                Logger.notification.info("posted notification '\(identifier, privacy: .public)'")
            } catch {
                Logger.notification.error(
                    "failed to post notification '\(identifier, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Withdraw an already-delivered notification whose ask is now moot.
    func remove(identifier: String) {
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        Logger.notification.info("removed notification '\(identifier, privacy: .public)'")
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        let engineID = request.content.userInfo[Self.settingsEngineIDKey] as? String
        Task { @MainActor in
            // A tap is an acknowledgement, so it shouldn't linger either way.
            remove(identifier: request.identifier)
            if let engineID {
                WindowManager.shared.openSettings(initialEngineID: engineID)
            }
        }
        completionHandler()
    }

    /// The default suppresses banners while this app is frontmost, which is
    /// exactly when its own settings are open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

/// First consumer of `NotificationManager`: notifies when a loaded external
/// engine's files change on disk, as an awareness and tamper-audit signal.
/// Opt-in, off by default. Covers only the currently-loaded engine, and only
/// while the input method is running.
@MainActor
final class EngineModifiedNotifier {
    static let shared = EngineModifiedNotifier()
    private init() {}

    static let enabledKey = "notifyOnEngineModified"
    static let promptedKey = "engineModifiedNotifyPrompted"
    private static let defaultEnabled = false
    /// Per-engine identifier, so a new notification replaces the previous one
    /// for that engine while distinct engines stay separate.
    private static func notificationID(engineID: String) -> String {
        "engineModified.\(engineID)"
    }

    /// A single save can reach the watcher as two batches; reusing the engine's
    /// identifier would then replace the banner with an identical one.
    private static let coalesceWindow = Duration.seconds(2)
    private var lastNotified: [String: ContinuousClock.Instant] = [:]

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? Self.defaultEnabled
    }

    /// Ask once, on the first external-engine pick, whether to enable
    /// notifications. Enabling flips the toggle and requests permission; either
    /// choice is remembered so we never ask again.
    func promptToEnableIfFirstTime(parent: NSWindow?) {
        guard !UserDefaults.standard.bool(forKey: Self.promptedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.promptedKey)
        guard !isEnabled else { return }

        Task {
            let alert = NSAlert()
            alert.messageText = String(localized: "Notify when engine files change?")
            alert.informativeText = String(localized: """
                Notifications help you spot unexpected edits to an external \
                engine's files. Change this later in the General settings tab.
                """)
            alert.addButton(withTitle: String(localized: "Enable Notifications"))
            alert.addButton(withTitle: String(localized: "Not Now"))

            let response: NSApplication.ModalResponse
            if let parent {
                response = await alert.beginSheetModal(for: parent)
            } else {
                response = alert.runModal()
            }
            if response == .alertFirstButtonReturn {
                UserDefaults.standard.set(true, forKey: Self.enabledKey)
                await NotificationManager.shared.requestAuthorization()
            }
        }
    }

    /// Withdraw an engine's change notification once the user has reloaded it,
    /// so it stops asking for something already done. Clearing the coalesce
    /// stamp too: a later change is a new event, not the duplicate batch the
    /// window guards against.
    func clearModified(engineID: String) {
        lastNotified[engineID] = nil
        NotificationManager.shared.remove(identifier: Self.notificationID(engineID: engineID))
    }

    /// Post a reload notification for an external engine, gated by the toggle
    /// (`NotificationManager` applies the authorization gate).
    func notifyModified(
        engineID: String, engineName: @autoclosure () -> String?,
        kind: InputEngine.ExternalSourceKind, changedFile: String,
        willReloadAutomatically: Bool
    ) {
        guard isEnabled else { return }
        let now = ContinuousClock.now
        if let last = lastNotified[engineID], last.duration(to: now) < Self.coalesceWindow {
            return
        }
        lastNotified[engineID] = now
        let name = engineName() ?? InputEngine.inputModeName(forEngineID: engineID)
        let file = URL(fileURLWithPath: changedFile).lastPathComponent
        let title: String
        switch kind {
        case .engine: title = String(format: String(localized: "“%@” engine updated"), name)
        case .table:  title = String(format: String(localized: "“%@” table updated"), name)
        }
        // An automatic reload needs nothing from the user, so it isn't a link.
        let body = willReloadAutomatically
            ? String(format: String(localized: "Detected a change to %@; reloading automatically."), file)
            : String(format: String(localized: "Detected a change to %@. Click to open Settings and reload manually."), file)
        NotificationManager.shared.post(
            identifier: Self.notificationID(engineID: engineID),
            title: title,
            body: body,
            settingsEngineID: willReloadAutomatically ? nil : engineID
        )
    }
}
