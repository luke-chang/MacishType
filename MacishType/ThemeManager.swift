import Cocoa
import OSLog

class ThemeManager {
    static let shared = ThemeManager()

    static let systemAppearanceDidChange = Notification.Name("ThemeManagerSystemAppearanceDidChange")

    private let accentColorKey = "AppleAccentColor"

    private(set) var isMulticolor: Bool
    private var bundleAccentColorCache: [String: NSColor?] = [:]
    private var appearanceObservation: NSKeyValueObservation?
    private var lastAccentColorValue: Int?
    private var lastAppearanceName: NSAppearance.Name?

    private init() {
        let raw = UserDefaults.standard.object(forKey: accentColorKey) as? Int
        isMulticolor = raw == nil
        lastAccentColorValue = raw
        lastAppearanceName = NSApp.effectiveAppearance.name
        #if DEBUG
        Logger.themeManager.debug("Initialized, isMulticolor=\(self.isMulticolor, privacy: .public) accentColor=\(String(describing: raw), privacy: .public) appearance=\(self.lastAppearanceName!.rawValue, privacy: .public)")
        #endif
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [unowned self] app, _ in
            let newRaw = UserDefaults.standard.object(forKey: self.accentColorKey) as? Int
            let newName = app.effectiveAppearance.name
            guard newRaw != self.lastAccentColorValue || newName != self.lastAppearanceName else { return }
            self.lastAccentColorValue = newRaw
            self.lastAppearanceName = newName
            self.isMulticolor = newRaw == nil
            #if DEBUG
            Logger.themeManager.debug("System appearance changed, isMulticolor=\(self.isMulticolor, privacy: .public) accentColor=\(String(describing: newRaw), privacy: .public) appearance=\(newName.rawValue, privacy: .public)")
            #endif
            NotificationCenter.default.post(name: Self.systemAppearanceDidChange, object: nil)
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
