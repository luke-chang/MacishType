import AppKit
import Combine
import SwiftUI
import UserNotifications

/// The "General" settings page: the keyboard-layout override (which Roman
/// layout keystrokes are read as), the predictive-completions selection-key
/// policy, and how external engines respond to their files changing
/// (automatic reload, notification).
struct GeneralSettingsView: View {
    @AppStorage(KeyboardLayouts.overrideDefaultsKey) private var layoutID = ""
    @AppStorage(InputEngine.associatedModeSelectionKeysKey)
    private var associatedSelectionKeys = InputEngine.AssociatedModeSelectionKeys.followEngine
    @AppStorage(InputEngine.autoReloadEnabledKey)
    private var autoReloadOnModified = InputEngine.defaultAutoReloadOnModified
    @AppStorage(EngineModifiedNotifier.enabledKey) private var notifyOnEngineModified = false
    @State private var notificationsDenied = false
    private let groups = LayoutGroup.all()

    var body: some View {
        InputEngine.settingsForm {
            Section {
                Picker("Keyboard layout", selection: $layoutID) {
                    Text("Follow system").tag("")
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.layouts) { layout in
                                Text(layout.name).tag(layout.id)
                            }
                        }
                    }
                }
            }
            Section("Predictive completions") {
                VStack(alignment: .leading, spacing: 2) {
                    Picker("Selection keys", selection: $associatedSelectionKeys) {
                        Text("Follow engine").tag(InputEngine.AssociatedModeSelectionKeys.followEngine)
                        Text("Number keys").tag(InputEngine.AssociatedModeSelectionKeys.numbers)
                        Text("Shift + number keys").tag(InputEngine.AssociatedModeSelectionKeys.shiftNumbers)
                    }
                    Text("Follow engine uses the engine's declared selection keys — number keys when it declares none — switching to Shift + number keys when they would collide with a CIN table's roots. Tinted number labels mean Shift is required.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section("External engines") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Reload automatically when files change", isOn: $autoReloadOnModified)
                    Text("When off, reload it manually from the engine's settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Notify when files change", isOn: $notifyOnEngineModified)
                    Text("Get a system notification when a loaded engine's files change. Engines you haven't switched to aren't loaded yet, so they aren't watched.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if notifyOnEngineModified, notificationsDenied {
                    InputEngine.InlineNoticeRow(
                        systemImage: "exclamationmark.triangle.fill",
                        message: "Notifications are turned off in System Settings.",
                        actionTitle: "Open System Settings"
                    ) {
                        NotificationManager.shared.openSystemNotificationSettings()
                    }
                }
            }
        }
        .task { await refreshAuthorizationStatus() }
        .onChange(of: notifyOnEngineModified) { _, newValue in
            guard newValue else {
                notificationsDenied = false
                return
            }
            // Await the request: it suspends until the user answers, so a denial
            // is reflected only once it's an explicit choice, never while pending.
            Task {
                let status = await NotificationManager.shared.requestAuthorization()
                notificationsDenied = (status == .denied)
            }
        }
        // No event fires on permission changes; re-check when the app regains
        // focus, since changing it means leaving for System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAuthorizationStatus() }
        }
    }

    private func refreshAuthorizationStatus() async {
        notificationsDenied = await NotificationManager.shared.authorizationStatus() == .denied
    }
}

/// A labeled group in the picker: a language (OS-localized name) or the trailing
/// "Other" bucket for single-layout languages.
private struct LayoutGroup: Identifiable {
    let id: String
    let title: String
    let layouts: [KeyboardLayout]

    /// English first, then each language with ≥2 layouts (ordered by localized
    /// language name), then one "Other" group for all single-layout languages.
    static func all() -> [LayoutGroup] {
        let byLanguage = Dictionary(grouping: KeyboardLayouts.asciiCapable(), by: \.language)
        func byName(_ layouts: [KeyboardLayout]) -> [KeyboardLayout] {
            layouts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        func languageName(_ code: String) -> String? {
            code.isEmpty ? nil : Locale.current.localizedString(forLanguageCode: code)
        }

        var groups: [LayoutGroup] = []
        var other: [KeyboardLayout] = []
        if let english = byLanguage["en"] {
            groups.append(LayoutGroup(id: "en", title: languageName("en") ?? "en", layouts: byName(english)))
        }
        // A language earns its own section only with ≥2 layouts and a resolvable
        // name; lone layouts and ones with no/unknown language fall to "Other".
        var named: [LayoutGroup] = []
        for (code, layouts) in byLanguage where code != "en" {
            if layouts.count >= 2, let name = languageName(code) {
                named.append(LayoutGroup(id: code, title: name, layouts: byName(layouts)))
            } else {
                other.append(contentsOf: layouts)
            }
        }
        groups += named.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if !other.isEmpty {
            groups.append(LayoutGroup(id: "__other__", title: String(localized: "Other"), layouts: byName(other)))
        }
        return groups
    }
}
