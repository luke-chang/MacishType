import Foundation
import Testing

struct AlertSoundTests {
    /// On by default; only an explicit false silences it. A private suite
    /// keeps the real preference domain untouched.
    @Test func alertSoundIsOnUnlessTurnedOff() throws {
        let suite = "AlertSoundTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AlertSound.isEnabled(in: defaults))
        defaults.set(false, forKey: AlertSound.enabledKey)
        #expect(!AlertSound.isEnabled(in: defaults))
        defaults.set(true, forKey: AlertSound.enabledKey)
        #expect(AlertSound.isEnabled(in: defaults))
    }
}
