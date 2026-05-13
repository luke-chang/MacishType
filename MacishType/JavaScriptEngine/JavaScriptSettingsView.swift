import Combine
import OSLog
import SwiftUI

// SwiftUI renderer for a JavaScriptEngine's manifest-declared settings.
// Lives next to JavaScriptManifest.swift (the schema) rather than under
// InputEngine, because none of this is generic across InputEngine
// subclasses — it's specifically driven by JavaScriptEngine's manifest.

// MARK: - ManifestSettingsStore

/// Observable wrapper around the `<engineID>_manifestSettings` UserDefaults
/// blob. KVO on the specific key catches both same-process and cross-process
/// writes (the latter via cfprefsd); `UserDefaults.didChangeNotification`
/// would miss cross-process. Without it, `defaults write` from the CLI
/// wouldn't update an open Settings window in real time.
@MainActor
final class ManifestSettingsStore: NSObject, ObservableObject {
    @Published private(set) var values: [String: JavaScriptEngine.JSONValue] = [:]
    private let storageKey: String

    // Sorted keys: stable `defaults read` output across writes so the raw
    // blob is reproducible / diff-friendly. Applies recursively to nested
    // JSONValue.object cases too.
    nonisolated private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    nonisolated private static let decoder = JSONDecoder()

    init(engineID: String) {
        self.storageKey = InputEngine.composedKey(
            engineID: engineID, subKey: InputEngine.manifestSettingsSubKey)
        super.init()
        reload()
        UserDefaults.standard.addObserver(
            self, forKeyPath: storageKey, options: [], context: nil)
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: storageKey)
    }

    // KVO callback fires on whatever thread the writer (or cfprefsd, for
    // cross-process writes) notifies on — hop to main before touching
    // @Published. nonisolated lets the ObjC dispatch through.
    override nonisolated func observeValue(
        forKeyPath keyPath: String?, of object: Any?,
        change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor [weak self] in self?.reload() }
    }

    private func reload() {
        let decoded = Self.decode(forKey: storageKey)
        // Dirty check absorbs self-write echoes and cfprefsd's occasional
        // duplicate KVO fires for a single cross-process write.
        if decoded != values { values = decoded }
    }

    /// Blob stored as JSON UTF-8 string rather than Data so `defaults read`
    /// from the CLI renders the content directly (escaped through plist's
    /// string literal, but readable) instead of opaque hex bytes.
    nonisolated static func decode(forKey key: String) -> [String: JavaScriptEngine.JSONValue] {
        guard let str = UserDefaults.standard.string(forKey: key),
              let data = str.data(using: .utf8),
              let dict = try? decoder.decode(
                [String: JavaScriptEngine.JSONValue].self, from: data)
        else { return [:] }
        return dict
    }

    nonisolated static func encode(
        _ dict: [String: JavaScriptEngine.JSONValue], forKey key: String
    ) {
        do {
            let data = try encoder.encode(dict)
            guard let str = String(data: data, encoding: .utf8) else {
                Logger.javaScriptEngine.error("manifestSettings encode failed: invalid UTF-8")
                return
            }
            UserDefaults.standard.set(str, forKey: key)
        } catch {
            Logger.javaScriptEngine.error(
                "manifestSettings encode failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    func write(_ value: JavaScriptEngine.JSONValue, for fieldKey: String) {
        var dict = values
        dict[fieldKey] = value
        Self.encode(dict, forKey: storageKey)
    }
}

// MARK: - EngineSettingsRenderer

extension JavaScriptEngine {
    /// Renders `manifest.settings` sections inside a settingsForm. Caller
    /// wraps in `InputEngine.settingsForm { ... }`. No-op when sections
    /// is nil / empty. Each FieldView binds to a shared
    /// `ManifestSettingsStore` so external writes propagate live via
    /// `UserDefaults.didChangeNotification`.
    struct EngineSettingsRenderer: View {
        let sections: [Manifest.SettingsSection]?
        @StateObject private var store: ManifestSettingsStore

        init(engine: JavaScriptEngine, sections: [Manifest.SettingsSection]?) {
            self.sections = sections
            _store = StateObject(wrappedValue: ManifestSettingsStore(engineID: engine.engineID))
        }

        var body: some View {
            if let sections, !sections.isEmpty {
                ForEach(sections.indices, id: \.self) { i in
                    SectionView(store: store, section: sections[i])
                }
            }
        }

        @ViewBuilder
        fileprivate static func fieldRow<Content: View>(
            description: Localizable?,
            @ViewBuilder control: () -> Content
        ) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                control()
                if let description {
                    Text(verbatim: description.resolved())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        private struct SectionView: View {
            @ObservedObject var store: ManifestSettingsStore
            let section: Manifest.SettingsSection

            /// Filter at section level (not inside FieldView body) so Form
            /// doesn't reserve an empty row for hidden fields.
            private var visibleFields: [Manifest.SettingsField] {
                section.fields.filter {
                    !($0.hiddenWhen?.evaluate(store.values) ?? false)
                }
            }

            var body: some View {
                if !visibleFields.isEmpty {
                    Section {
                        // id: \.key — index-based identity would reuse
                        // @State / @FocusState across slots after filtering.
                        ForEach(visibleFields, id: \.key) { field in
                            FieldView(store: store, field: field)
                        }
                    } header: {
                        Text(verbatim: section.title.resolved())
                    } footer: {
                        if let d = section.description {
                            Text(verbatim: d.resolved())
                        }
                    }
                }
            }
        }

        private struct FieldView: View {
            @ObservedObject var store: ManifestSettingsStore
            let field: Manifest.SettingsField

            var body: some View {
                Group {
                    switch field {
                    case .picker(let f):      PickerFieldView(store: store, field: f)
                    case .toggle(let f):      ToggleFieldView(store: store, field: f)
                    case .textField(let f):   TextFieldFieldView(store: store, field: f)
                    case .number(let f):      NumberFieldView(store: store, field: f)
                    case .multiSelect(let f): MultiSelectFieldView(store: store, field: f)
                    }
                }
                .disabled(field.disabledWhen?.evaluate(store.values) ?? false)
            }
        }

        // MARK: PickerFieldView

        private struct PickerFieldView: View {
            @ObservedObject var store: ManifestSettingsStore
            let field: Manifest.PickerField

            /// `.auto` collapses here so the dispatch switch below has no
            /// unreachable case.
            private enum ResolvedStyle { case menu, radioGroup }

            /// Reject stored values that don't match any current option —
            /// SwiftUI Picker misbehaves with a selection it can't find.
            private var binding: Binding<JSONValue> {
                Binding(
                    get: {
                        if let stored = store.values[field.key],
                           field.options.contains(where: { $0.value == stored }) {
                            return stored
                        }
                        return field.defaultValue
                    },
                    set: { store.write($0, for: field.key) }
                )
            }
            private var resolvedStyle: ResolvedStyle {
                switch field.style ?? .auto {
                case .auto:       return field.options.count <= 3 ? .radioGroup : .menu
                case .menu:       return .menu
                case .radioGroup: return .radioGroup
                }
            }

            var body: some View {
                EngineSettingsRenderer.fieldRow(description: field.description) {
                    picker
                }
            }

            @ViewBuilder private var picker: some View {
                let p = Picker(selection: binding) {
                    ForEach(field.options.indices, id: \.self) { i in
                        Text(verbatim: field.options[i].text.resolved())
                            .tag(field.options[i].value)
                    }
                } label: {
                    Text(verbatim: field.label.resolved())
                }
                switch resolvedStyle {
                case .menu:       p.pickerStyle(.menu)
                case .radioGroup: p.pickerStyle(.radioGroup)
                }
            }
        }

        // MARK: ToggleFieldView

        private struct ToggleFieldView: View {
            @ObservedObject var store: ManifestSettingsStore
            let field: Manifest.ToggleField

            private var binding: Binding<Bool> {
                Binding(
                    get: {
                        if case .bool(let v) = store.values[field.key] { return v }
                        return field.default
                    },
                    set: { store.write(.bool($0), for: field.key) }
                )
            }

            var body: some View {
                EngineSettingsRenderer.fieldRow(description: field.description) {
                    Toggle(isOn: binding) {
                        Text(verbatim: field.label.resolved())
                    }
                }
            }
        }

        // MARK: TextFieldFieldView

        private struct TextFieldFieldView: View {
            @ObservedObject var store: ManifestSettingsStore
            let field: Manifest.TextFieldField

            @State private var localText: String = ""
            @FocusState private var isFocused: Bool

            private static func unwrap(
                _ values: [String: JSONValue],
                field: Manifest.TextFieldField
            ) -> String {
                if case .string(let v) = values[field.key] { return v }
                return field.default
            }

            var body: some View {
                EngineSettingsRenderer.fieldRow(description: field.description) {
                    textFieldRow
                }
                .onAppear { localText = Self.unwrap(store.values, field: field) }
                .onChange(of: store.values) { _, newValues in
                    // External write (store reload after notification fire):
                    // sync to localText while user isn't editing.
                    guard !isFocused else { return }
                    let synced = Self.unwrap(newValues, field: field)
                    if synced != localText { localText = synced }
                }
                .onChange(of: isFocused) { _, focused in
                    // Commit on blur — matches macOS system settings behavior
                    // where moving focus away saves the field. Enter (.onSubmit
                    // below) is the alternate commit trigger.
                    if !focused { commit() }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.willResignActiveNotification)
                ) { _ in
                    // App going to background while user is mid-edit (Cmd-Tab
                    // away, click another app). SwiftUI's @FocusState isn't
                    // tied to app-active state, so onChange(of: isFocused)
                    // doesn't fire here.
                    if isFocused { commit() }
                }
            }

            @ViewBuilder private var textFieldRow: some View {
                TextField(
                    text: $localText,
                    prompt: field.placeholder.map { Text(verbatim: $0.resolved()) },
                    label: { Text(verbatim: field.label.resolved()) }
                )
                .focused($isFocused)
                .onSubmit { commit() }
            }

            private func commit() {
                store.write(.string(localText), for: field.key)
            }
        }

        // MARK: NumberFieldView

        private struct NumberFieldView: View {
            @ObservedObject var store: ManifestSettingsStore
            let field: Manifest.NumberField

            private var current: Double {
                if case .number(let v) = store.values[field.key] { return v }
                return field.default
            }
            private var binding: Binding<Double> {
                Binding(
                    get: { current },
                    set: { store.write(.number($0), for: field.key) }
                )
            }
            private var bounds: ClosedRange<Double> {
                let lo = field.min ?? -.greatestFiniteMagnitude
                let hi = field.max ?? .greatestFiniteMagnitude
                return lo...hi
            }
            private var stepValue: Double { field.step ?? 1 }
            private var formattedValue: String {
                stepValue.truncatingRemainder(dividingBy: 1) == 0
                    ? String(Int(current))
                    : String(format: "%.2f", current)
            }

            var body: some View {
                EngineSettingsRenderer.fieldRow(description: field.description) {
                    Stepper(value: binding, in: bounds, step: stepValue) {
                        HStack {
                            Text(verbatim: field.label.resolved())
                            Spacer()
                            Text(verbatim: formattedValue)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        // MARK: MultiSelectFieldView

        private struct MultiSelectFieldView: View {
            @ObservedObject var store: ManifestSettingsStore
            let field: Manifest.MultiSelectField

            /// Stale entries (values not in current options) are silently
            /// dropped — a checkbox the user can't uncheck would be worse
            /// than ignoring it. All-invalid stays empty so an intentional
            /// clear isn't overridden; missing key falls back to defaults.
            private var current: [JSONValue] {
                guard let stored = store.values[field.key] else {
                    return field.defaultValues
                }
                guard case .array(let arr) = stored else {
                    return field.defaultValues
                }
                return arr.filter { stored in
                    field.options.contains { $0.value == stored }
                }
            }

            private func isSelected(_ value: JSONValue) -> Bool {
                current.contains(value)
            }

            private func toggle(_ value: JSONValue, on: Bool) {
                var next = current
                if on {
                    if !next.contains(value) { next.append(value) }
                } else {
                    next.removeAll { $0 == value }
                }
                store.write(.array(next), for: field.key)
            }

            var body: some View {
                EngineSettingsRenderer.fieldRow(description: field.description) {
                    Text(verbatim: field.label.resolved())
                    ForEach(field.options.indices, id: \.self) { i in
                        let option = field.options[i]
                        Toggle(isOn: Binding(
                            get: { isSelected(option.value) },
                            set: { toggle(option.value, on: $0) }
                        )) {
                            Text(verbatim: option.text.resolved())
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }
}
