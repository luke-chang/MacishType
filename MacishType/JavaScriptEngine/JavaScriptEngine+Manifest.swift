import Foundation
import OSLog

// Each top-level type is marked `nonisolated` so its Decodable conformance
// is callable from `nonisolated static` parsers like `parseManifest(in:)`.
// Without it, Swift 6 infers main-actor isolation from the enclosing
// `JavaScriptEngine` and parsers can't decode without actor hops. Pure
// data types don't touch UI state, so opting out is safe.
extension JavaScriptEngine {

    // MARK: Manifest

    nonisolated struct Manifest: Decodable {
        let entry: String
        let candidateWindow: CandidateWindowOverrides?
        let settings: [SettingsSection]?

        private enum CodingKeys: String, CodingKey { case entry, candidateWindow, settings }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // entry is required: missing / type-mismatch fails the manifest.
            entry = try c.decode(String.self, forKey: .entry)
            // candidateWindow wrapper type-mismatch (e.g. user wrote a
            // string) drops the sub-tree but lets entry still load.
            do {
                candidateWindow = try c.decodeIfPresent(
                    CandidateWindowOverrides.self, forKey: .candidateWindow)
            } catch {
                Logger.javaScriptEngine.error(
                    "manifest candidateWindow ignored: \(String(describing: error), privacy: .public)"
                )
                candidateWindow = nil
            }
            settings = Self.decodeTolerantSettings(from: c)
        }

        /// Per-element tolerant decode for `settings`. Wrapper type-mismatch
        /// → nil + log. Per-section element fail → drop that section + log,
        /// keep other sections. Section internals (per-field tolerance)
        /// live in `SettingsSection.init`.
        private static func decodeTolerantSettings(
            from c: KeyedDecodingContainer<CodingKeys>
        ) -> [SettingsSection]? {
            guard c.contains(.settings) else { return nil }
            var arr: UnkeyedDecodingContainer
            do {
                arr = try c.nestedUnkeyedContainer(forKey: .settings)
            } catch {
                Logger.javaScriptEngine.error(
                    "manifest settings ignored: \(String(describing: error), privacy: .public)"
                )
                return nil
            }
            var collected: [SettingsSection] = []
            while !arr.isAtEnd {
                do {
                    collected.append(try arr.decode(SettingsSection.self))
                } catch {
                    // Consume the bad slot so the decoder's currentIndex
                    // advances; AnyDecodable's empty init always succeeds.
                    _ = try? arr.decode(AnyDecodable.self)
                    Logger.javaScriptEngine.error(
                        "manifest settings section dropped: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            return collected
        }

        /// Per-field defensive decode: type mismatches AND value-level
        /// violations (range, charset) are dropped + logged ONCE at decode
        /// time. Keeps the hot-path `candidateWindowConfiguration` getter
        /// free of validation work and per-keystroke log spam.
        struct CandidateWindowOverrides: Decodable {
            var layoutDirection: CandidateWindow.LayoutDirection?
            var fontSize: Int?
            var indexLabels: String?
            var pageSize: Int?
            var widerExpandedColumns: Bool?
            var moveOnExpand: Bool?
            var horizontalMaxVisibleRows: Int?
            var verticalMinVisibleRows: Int?
            var expandable: Bool?
            var handleNavigationKeys: Bool?
            var handleIndexLabelKeys: Bool?

            private enum CodingKeys: String, CodingKey {
                case layoutDirection, fontSize, indexLabels, pageSize
                case widerExpandedColumns, moveOnExpand
                case horizontalMaxVisibleRows, verticalMinVisibleRows, expandable
                case handleNavigationKeys, handleIndexLabelKeys
            }

            init(
                layoutDirection: CandidateWindow.LayoutDirection? = nil,
                fontSize: Int? = nil,
                indexLabels: String? = nil,
                pageSize: Int? = nil,
                widerExpandedColumns: Bool? = nil,
                moveOnExpand: Bool? = nil,
                horizontalMaxVisibleRows: Int? = nil,
                verticalMinVisibleRows: Int? = nil,
                expandable: Bool? = nil,
                handleNavigationKeys: Bool? = nil,
                handleIndexLabelKeys: Bool? = nil
            ) {
                self.layoutDirection = layoutDirection
                self.fontSize = fontSize
                self.indexLabels = indexLabels
                self.pageSize = pageSize
                self.widerExpandedColumns = widerExpandedColumns
                self.moveOnExpand = moveOnExpand
                self.horizontalMaxVisibleRows = horizontalMaxVisibleRows
                self.verticalMinVisibleRows = verticalMinVisibleRows
                self.expandable = expandable
                self.handleNavigationKeys = handleNavigationKeys
                self.handleIndexLabelKeys = handleIndexLabelKeys
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                layoutDirection = Self.tolerant(c, .layoutDirection, as: CandidateWindow.LayoutDirection.self)
                fontSize = Self.tolerant(c, .fontSize, as: Int.self)
                widerExpandedColumns = Self.tolerant(c, .widerExpandedColumns, as: Bool.self)
                moveOnExpand = Self.tolerant(c, .moveOnExpand, as: Bool.self)
                horizontalMaxVisibleRows = Self.tolerant(c, .horizontalMaxVisibleRows, as: Int.self)
                verticalMinVisibleRows = Self.tolerant(c, .verticalMinVisibleRows, as: Int.self)
                expandable = Self.tolerant(c, .expandable, as: Bool.self)
                handleNavigationKeys = Self.tolerant(c, .handleNavigationKeys, as: Bool.self)
                handleIndexLabelKeys = Self.tolerant(c, .handleIndexLabelKeys, as: Bool.self)

                // CandidateWindowConfiguration has didSet preconditions on
                // these two (always-on, not stripped in release). Validate
                // here so out-of-range manifest values don't crash later.
                indexLabels = Self.validateIndexLabels(
                    Self.tolerant(c, .indexLabels, as: String.self))
                pageSize = Self.validatePageSize(
                    Self.tolerant(c, .pageSize, as: Int.self))
            }

            private static func tolerant<T: Decodable>(
                _ container: KeyedDecodingContainer<CodingKeys>,
                _ key: CodingKeys, as type: T.Type
            ) -> T? {
                do {
                    return try container.decodeIfPresent(T.self, forKey: key)
                } catch {
                    Logger.javaScriptEngine.error(
                        "manifest candidateWindow.\(key.stringValue, privacy: .public) ignored: \(String(describing: error), privacy: .public)"
                    )
                    return nil
                }
            }

            private static func validateIndexLabels(_ raw: String?) -> String? {
                guard let v = raw else { return nil }
                if CandidateWindowConfiguration.isValidIndexLabels(v) { return v }
                Logger.javaScriptEngine.error(
                    "manifest indexLabels rejected (non-ASCII-printable): \(v, privacy: .public)"
                )
                return nil
            }

            private static func validatePageSize(_ raw: Int?) -> Int? {
                guard let v = raw else { return nil }
                if CandidateWindowConfiguration.isValidPageSize(v) { return v }
                Logger.javaScriptEngine.error(
                    "manifest pageSize out of range \(CandidateWindowConfiguration.validPageSizeRange, privacy: .public): \(v, privacy: .public)"
                )
                return nil
            }
        }

        // MARK: Settings schema

        struct SettingsSection: Decodable {
            let title: Localizable
            let description: Localizable?
            let fields: [SettingsField]

            private enum CodingKeys: String, CodingKey { case title, description, fields }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                // title required: throw bubbles up so Manifest drops this
                // entire section (and logs which one died).
                title = try c.decode(Localizable.self, forKey: .title)
                // description tolerant: missing OK, type-mismatch silent nil
                // (the section content is more valuable than its caption).
                description = try? c.decode(Localizable.self, forKey: .description)
                // Per-field tolerance: broken field dropped + logged; section
                // still renders with the remaining fields.
                var arr = try c.nestedUnkeyedContainer(forKey: .fields)
                var collected: [SettingsField] = []
                while !arr.isAtEnd {
                    do {
                        collected.append(try arr.decode(SettingsField.self))
                    } catch {
                        _ = try? arr.decode(AnyDecodable.self)
                        Logger.javaScriptEngine.error(
                            "manifest settings field dropped: \(String(describing: error), privacy: .public)"
                        )
                    }
                }
                fields = collected
            }
        }

        enum SettingsField: Decodable {
            case picker(PickerField)
            case toggle(ToggleField)
            case textField(TextFieldField)
            case number(NumberField)
            case multiSelect(MultiSelectField)
            case system(SystemField)

            var key: String {
                switch self {
                case .picker(let f):      return f.key
                case .toggle(let f):      return f.key
                case .textField(let f):   return f.key
                case .number(let f):      return f.key
                case .multiSelect(let f): return f.key
                case .system(let f):      return f.key
                }
            }

            private enum TypeKey: String, CodingKey { case type }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: TypeKey.self)
                let type = try c.decode(String.self, forKey: .type)
                switch type {
                case "picker":      self = .picker(try PickerField(from: decoder))
                case "toggle":      self = .toggle(try ToggleField(from: decoder))
                case "textField":   self = .textField(try TextFieldField(from: decoder))
                case "number":      self = .number(try NumberField(from: decoder))
                case "multiSelect": self = .multiSelect(try MultiSelectField(from: decoder))
                case "system":      self = .system(try SystemField(from: decoder))
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: TypeKey.type, in: c,
                        debugDescription: "unknown settings field type: \(type)"
                    )
                }
            }
        }

        /// Borrows a host-provided UI / label / storage. `key` picks the
        /// feature (currently only `"enableAssociatedMode"`); unknown keys
        /// throw at decode.
        struct SystemField: Decodable {
            static let supportedKeys: Set<String> = ["enableAssociatedMode"]

            let key: String
            let defaultValue: Bool?

            private enum CodingKeys: String, CodingKey {
                case key, defaultValue = "default"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let parsedKey = try c.decode(String.self, forKey: .key)
                guard Self.supportedKeys.contains(parsedKey) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: CodingKeys.key, in: c,
                        debugDescription: "unknown system field key: \(parsedKey)"
                    )
                }
                self.key = parsedKey
                self.defaultValue = try c.decodeIfPresent(Bool.self, forKey: .defaultValue)
            }
        }

        struct PickerField: Decodable {
            let key: String
            let label: Localizable
            let description: Localizable?
            let options: [PickerOption]
            let style: PickerStyle?
            let `default`: PickerDefault?
            let disabledWhen: Condition?
            let hiddenWhen: Condition?
        }

        struct ToggleField: Decodable {
            let key: String
            let label: Localizable
            let description: Localizable?
            let `default`: Bool
            let disabledWhen: Condition?
            let hiddenWhen: Condition?
        }

        struct TextFieldField: Decodable {
            let key: String
            let label: Localizable
            let description: Localizable?
            let placeholder: Localizable?
            let `default`: String?
            let disabledWhen: Condition?
            let hiddenWhen: Condition?
        }

        struct NumberField: Decodable {
            let key: String
            let label: Localizable
            let description: Localizable?
            let min: Double?
            let max: Double?
            let step: Double?
            let `default`: Double
            let disabledWhen: Condition?
            let hiddenWhen: Condition?
        }

        struct MultiSelectField: Decodable {
            let key: String
            let label: Localizable
            let description: Localizable?
            let options: [PickerOption]
            let `default`: [PickerDefault]?
            let disabledWhen: Condition?
            let hiddenWhen: Condition?
        }

        struct PickerOption: Decodable {
            let text: Localizable
            let value: JSONValue
            let tag: String?

            private enum CodingKeys: String, CodingKey { case text, value, tag }

            init(from decoder: Decoder) throws {
                // Shorthand: `"foo"` → text/value/tag all become "foo".
                if let s = try? decoder.singleValueContainer().decode(String.self) {
                    self.text = .literal(s)
                    self.value = .string(s)
                    self.tag = s
                    return
                }
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let text = try c.decode(Localizable.self, forKey: .text)

                // When text is a localized map, value MUST be explicit (otherwise
                // throw — the parent picker / multiSelect is dropped wholesale by
                // SettingsSection's tolerant decode). tag stays optional even
                // there: a missing tag just means the option can't be referenced
                // by tag-based `default`.
                let textLiteral: String? = {
                    if case .literal(let s) = text { return s } else { return nil }
                }()

                let value: JSONValue
                if let v = try? c.decode(JSONValue.self, forKey: .value) {
                    value = v
                } else if let s = textLiteral {
                    value = .string(s)
                } else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .value, in: c,
                        debugDescription: "value required when text is localized")
                }

                let tag: String?
                if let t = try? c.decode(String.self, forKey: .tag) {
                    tag = t
                } else if let s = textLiteral {
                    tag = s
                } else {
                    tag = nil
                }

                self.text = text
                self.value = value
                self.tag = tag
            }
        }

        /// Top-level `default` for picker / multiSelect fields. Manifest
        /// authors reference an option by index (Int) or tag (String). The
        /// referenced option's `value` is resolved at use time (see
        /// `PickerField.defaultValue` / `MultiSelectField.defaultValues`).
        ///
        /// A String default ONLY matches against option `tag`, never `value`.
        /// `value` may be an object/array/number/bool — string equality won't
        /// generalize. Authors who want to reference by value must give the
        /// option an explicit `tag` matching that name.
        enum PickerDefault: Decodable {
            case index(Int)
            case tag(String)

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                // Int first; otherwise a numeric JSON literal would decode as String.
                if let i = try? c.decode(Int.self) { self = .index(i); return }
                if let s = try? c.decode(String.self) { self = .tag(s); return }
                throw DecodingError.typeMismatch(
                    PickerDefault.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "expected Int (index) or String (tag)"
                    )
                )
            }
        }

        /// Cases align with SwiftUI `.pickerStyle(.menu)` / `.radioGroup`
        /// so manifest authors who know SwiftUI aren't surprised by a
        /// different name. `auto` resolves at render time by options count.
        enum PickerStyle: String, Decodable { case auto, menu, radioGroup }

        /// Recursive boolean condition for `disabledWhen` / `hiddenWhen`.
        /// Bad structure throws (not silently treated as "no condition") so
        /// `SettingsSection`'s per-field tolerant decode drops the offending
        /// field — a broken rule should surface as a missing UI, not as a
        /// field that quietly ignores its own constraint.
        indirect enum Condition: Decodable {
            case leaf(key: String, op: Operator)
            case allOf([Condition])
            case anyOf([Condition])
            case not(Condition)

            enum Operator {
                case equals(JSONValue)
                case notEquals(JSONValue)
                case `in`([JSONValue])
                case notIn([JSONValue])
            }

            private enum CodingKeys: String, CodingKey {
                case key, equals, notEquals, `in`, notIn, allOf, anyOf, not
            }

            init(from decoder: Decoder) throws {
                if let arr = try? decoder.singleValueContainer().decode([Condition].self) {
                    self = .allOf(arr); return
                }
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if let inner = try? c.decode([Condition].self, forKey: .allOf) {
                    self = .allOf(inner); return
                }
                if let inner = try? c.decode([Condition].self, forKey: .anyOf) {
                    self = .anyOf(inner); return
                }
                if let inner = try? c.decode(Condition.self, forKey: .not) {
                    self = .not(inner); return
                }
                let key = try c.decode(String.self, forKey: .key)
                if let v = try? c.decode(JSONValue.self, forKey: .equals) {
                    self = .leaf(key: key, op: .equals(v)); return
                }
                if let v = try? c.decode(JSONValue.self, forKey: .notEquals) {
                    self = .leaf(key: key, op: .notEquals(v)); return
                }
                if let vs = try? c.decode([JSONValue].self, forKey: .in) {
                    self = .leaf(key: key, op: .in(vs)); return
                }
                if let vs = try? c.decode([JSONValue].self, forKey: .notIn) {
                    self = .leaf(key: key, op: .notIn(vs)); return
                }
                throw DecodingError.dataCorruptedError(
                    forKey: .key, in: c,
                    debugDescription: "leaf condition needs one of: equals, notEquals, in, notIn"
                )
            }
        }
    }

    // MARK: Manifest helper types

    /// Manifest-resolved localized string. Decodes from a literal `String`
    /// or a `{ <locale>: <String> }` map. Resolution at render time:
    /// `Bundle.main.preferredLocalizations` order → `"en"` → lowest key
    /// (sorted; `Dictionary.first` would flicker between launches).
    nonisolated enum Localizable: Decodable {
        case literal(String)
        case map([String: String])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .literal(s); return }
            self = .map(try c.decode([String: String].self))
        }

        func resolved() -> String {
            switch self {
            case .literal(let s): return s
            case .map(let dict):
                for code in Bundle.main.preferredLocalizations {
                    if let v = dict[code] { return v }
                }
                if let v = dict["en"] { return v }
                return dict.keys.sorted().first.flatMap { dict[$0] } ?? ""
            }
        }
    }

    /// Full JSON value tree — string / number / bool / null / array / object.
    /// Used for option values (`PickerOption.value`) and stored settings
    /// (`<engineID>_manifestSettings` blob). Hashable so SwiftUI Picker tags
    /// work for object cases via Swift-synthesized deep equality.
    nonisolated indirect enum JSONValue: Hashable, Codable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            // Bool first: some JSONDecoder versions accept `true` as Double 1.0.
            if let v = try? c.decode(Bool.self) { self = .bool(v); return }
            if let v = try? c.decode(Double.self) { self = .number(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
            if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "invalid JSON value"
                )
            )
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null:           try c.encodeNil()
            case .bool(let v):    try c.encode(v)
            case .number(let v):  try c.encode(v)
            case .string(let v):  try c.encode(v)
            case .array(let v):   try c.encode(v)
            case .object(let v):  try c.encode(v)
            }
        }
    }

    /// Sentinel for advancing an UnkeyedDecodingContainer past a slot
    /// that failed to decode as the target type. Without consuming the
    /// slot, the decoder's currentIndex doesn't move and the loop spins.
    fileprivate nonisolated struct AnyDecodable: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

// MARK: - PickerDefault resolution

extension JavaScriptEngine.Manifest.PickerDefault {
    /// nil for unresolvable index (out of range) or tag (no matching option).
    func resolve(
        against options: [JavaScriptEngine.Manifest.PickerOption]
    ) -> JavaScriptEngine.JSONValue? {
        switch self {
        case .index(let i):
            return options.indices.contains(i) ? options[i].value : nil
        case .tag(let t):
            return options.first { $0.tag == t }?.value
        }
    }
}

extension JavaScriptEngine.Manifest.PickerField {
    /// Resolved value of `default`. Falls back to options[0]'s value when
    /// `default` is missing or unresolvable; `.null` only when `options` is
    /// empty (manifest schema bug — picker with no options).
    var defaultValue: JavaScriptEngine.JSONValue {
        self.default?.resolve(against: options) ?? options.first?.value ?? .null
    }
}

extension JavaScriptEngine.Manifest.MultiSelectField {
    /// Unresolvable entries silently skipped; empty array when `default` is nil.
    var defaultValues: [JavaScriptEngine.JSONValue] {
        (self.default ?? []).compactMap { $0.resolve(against: options) }
    }
}

// MARK: - SettingsField schema introspection

extension JavaScriptEngine.Manifest.SettingsField {
    /// Whether a stored `JSONValue` matches the schema this field declares.
    /// Picker / multiSelect require the value (or each array element) to
    /// match an option's declared value — out-of-set values are rejected.
    func accepts(_ v: JavaScriptEngine.JSONValue) -> Bool {
        switch self {
        case .toggle:
            if case .bool = v { return true }
        case .textField:
            if case .string = v { return true }
        case .number:
            if case .number = v { return true }
        case .picker(let f):
            return f.options.contains { $0.value == v }
        case .multiSelect(let f):
            if case .array(let arr) = v {
                return arr.allSatisfy { stored in f.options.contains { $0.value == stored } }
            }
        case .system:
            // System fields are intercepted in sanitizedSettings; returning
            // false here means any stale blob entry falls through to the
            // default path (also intercepted) and gets discarded.
            return false
        }
        return false
    }

    /// Field-declared default expressed as `JSONValue`. For picker / multiSelect
    /// this routes through `PickerDefault.resolve`; scalar fields wrap their
    /// typed `default` property.
    var defaultJSONValue: JavaScriptEngine.JSONValue {
        switch self {
        case .toggle(let f):      return .bool(f.default)
        case .textField(let f):   return .string(f.default ?? "")
        case .number(let f):      return .number(f.default)
        case .picker(let f):      return f.defaultValue
        case .multiSelect(let f): return .array(f.defaultValues)
        case .system(let f):      return .bool(f.defaultValue ?? false)
        }
    }

    var disabledWhen: JavaScriptEngine.Manifest.Condition? {
        switch self {
        case .picker(let f):      return f.disabledWhen
        case .toggle(let f):      return f.disabledWhen
        case .textField(let f):   return f.disabledWhen
        case .number(let f):      return f.disabledWhen
        case .multiSelect(let f): return f.disabledWhen
        case .system:             return nil   // not supported on system fields
        }
    }

    var hiddenWhen: JavaScriptEngine.Manifest.Condition? {
        switch self {
        case .picker(let f):      return f.hiddenWhen
        case .toggle(let f):      return f.hiddenWhen
        case .textField(let f):   return f.hiddenWhen
        case .number(let f):      return f.hiddenWhen
        case .multiSelect(let f): return f.hiddenWhen
        case .system:             return nil
        }
    }
}

// MARK: - Condition evaluation

extension JavaScriptEngine.Manifest.Condition {
    /// Lookup missing key resolves to `.null`. Operator semantics against
    /// `.null` are well-defined (Hashable JSONValue): `equals: null` → true,
    /// `equals: x` (x ≠ null) → false, `notEquals: x` → true, `notIn: [...]`
    /// → true (assuming `.null` not in the list). A typo'd key therefore
    /// flips `notEquals` / `notIn` to permanently satisfied — manifest
    /// authors must diff-check before shipping a rename.
    func evaluate(_ values: [String: JavaScriptEngine.JSONValue]) -> Bool {
        switch self {
        case .leaf(let key, let op):
            let v = values[key] ?? .null
            switch op {
            case .equals(let x):    return v == x
            case .notEquals(let x): return v != x
            case .in(let xs):       return xs.contains(v)
            case .notIn(let xs):    return !xs.contains(v)
            }
        case .allOf(let cs): return cs.allSatisfy { $0.evaluate(values) }
        case .anyOf(let cs): return cs.contains   { $0.evaluate(values) }
        case .not(let c):    return !c.evaluate(values)
        }
    }
}
