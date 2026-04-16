import Cocoa
import OSLog

class ThemeManager {
    static let shared = ThemeManager()

    static let accentColorDidChange = Notification.Name("ThemeManagerAccentColorDidChange")

    private let accentColorKey = "AppleAccentColor"
    private let colorPreferencesNotification = Notification.Name("AppleColorPreferencesChangedNotification")

    private(set) var isMulticolor: Bool
    private var bundleAccentColorCache: [String: NSColor?] = [:]

    private init() {
        isMulticolor = UserDefaults.standard.object(forKey: accentColorKey) == nil
        DistributedNotificationCenter.default().addObserver(
            forName: colorPreferencesNotification,
            object: nil,
            queue: .main
        ) { [unowned self] _ in
            let wasMulticolor = self.isMulticolor
            self.isMulticolor = UserDefaults.standard.object(forKey: self.accentColorKey) == nil
            Logger.themeManager.info("Accent color setting changed - multicolor: \(self.isMulticolor, privacy: .public)")
            if self.isMulticolor != wasMulticolor {
                NotificationCenter.default.post(name: Self.accentColorDidChange, object: nil)
            }
        }
    }

    func bundleAccentColor(bundleIdentifier bundleID: String) -> NSColor? {
        if let cached = bundleAccentColorCache[bundleID] {
            return cached
        }
        guard let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let appBundle = Bundle(url: bundleURL),
              let colorName = appBundle.object(forInfoDictionaryKey: "NSAccentColorName") as? String,
              let color = NSColor(named: colorName, bundle: appBundle)
        else {
            bundleAccentColorCache[bundleID] = .some(nil)
            return nil
        }
        Logger.themeManager.info("Resolved bundle accent color for \(bundleID, privacy: .public)")
        bundleAccentColorCache[bundleID] = color
        return color
    }
}
