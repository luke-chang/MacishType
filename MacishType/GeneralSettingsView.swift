import SwiftUI

/// The "General" settings page — currently just the keyboard-layout override
/// (which Roman layout keystrokes are read as).
struct GeneralSettingsView: View {
    @AppStorage(KeyboardLayouts.overrideDefaultsKey) private var layoutID = ""
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
        }
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
