import AppKit

/// The desktop's alert sound, behind the user's opt-out.
enum AlertSound {
    nonisolated static let enabledKey = "engineAlertSounds"
    nonisolated static let defaultEnabled = true

    nonisolated static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    /// `NSSound.beep()` returns long before the sound does, so this runs on
    /// the key path; overlapping requests are the system's to merge.
    static func play() {
        guard isEnabled() else { return }
        NSSound.beep()
    }
}
