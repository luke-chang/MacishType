import Foundation
import OSLog

/// Locale-keyed, reference-counted loader for a bundled dictionary resource.
/// Callers `acquire(for:)` a `Handle`; the first acquire for a locale loads and
/// parses `<resourceBaseName>.<locale>.txt`, the last release unloads it.
///
/// The parsed `Value` is opaque to this component: `parse` builds it from the
/// file contents. Main-thread access only (no locking).
final class RefCountedDictionary<Value> {
    private struct Slot {
        let value: Value
        var count: Int
    }

    // Single source of truth for value + refcount, keyed by locale. Each
    // instance owns its own map, so distinct dictionaries never share state.
    private var slots: [String: Slot] = [:]

    // Bundle resource presence by locale; `isAvailable` may run often (e.g. on
    // every Settings render), so cache the one-time probe. Bundled resources
    // don't change at runtime, so entries never invalidate.
    private var availabilityCache: [String: Bool] = [:]

    private let resourceBaseName: String
    private let logger: Logger
    private let parse: (String) -> Value

    init(resourceBaseName: String, logger: Logger,
         parse: @escaping (String) -> Value) {
        self.resourceBaseName = resourceBaseName
        self.logger = logger
        self.parse = parse
    }

    // Workaround for an open swiftc bug (swiftlang/swift#88173): under -O with
    // -default-isolation MainActor, the performance inliner crashes in
    // isCallerAndCalleeLayoutConstraintsCompatible during whole-module optimization.
    // It happens to manifest on this class's synthesized deallocating deinit;
    // opting the deinit out sidesteps it while keeping -O for the rest of the module.
    @_optimize(none)
    deinit {}

    private func resourceName(for locale: String) -> String {
        "\(resourceBaseName).\(locale)"
    }

    /// True when `<resourceBaseName>.<locale>.txt` is bundled. Lets callers gate
    /// behavior without loading the dictionary.
    func isAvailable(for locale: String) -> Bool {
        if let cached = availabilityCache[locale] { return cached }
        let present = Bundle.main.url(
            forResource: resourceName(for: locale), withExtension: "txt") != nil
        availabilityCache[locale] = present
        return present
    }

    /// Acquire a strong reference; the returned `Handle`'s lifetime governs the
    /// refcount.
    func acquire(for locale: String) -> Handle {
        let value: Value
        if var slot = slots[locale] {
            slot.count += 1
            slots[locale] = slot
            value = slot.value
            #if DEBUG
            logger.debug("\(self.resourceBaseName, privacy: .public).\(locale, privacy: .public) acquired (refcount=\(slot.count, privacy: .public))")
            #endif
        } else {
            let loaded = load(locale: locale)
            slots[locale] = Slot(value: loaded, count: 1)
            value = loaded
            #if DEBUG
            logger.debug("\(self.resourceBaseName, privacy: .public).\(locale, privacy: .public) loaded (refcount=1)")
            #endif
        }
        return Handle(value: value) { [weak self] in
            self?.release(locale: locale)
        }
    }

    private func release(locale: String) {
        guard var slot = slots[locale], slot.count > 0 else {
            logger.fault("\(self.resourceBaseName, privacy: .public).\(locale, privacy: .public) released below zero")
            return
        }
        slot.count -= 1
        if slot.count == 0 {
            slots.removeValue(forKey: locale)
            #if DEBUG
            logger.debug("\(self.resourceBaseName, privacy: .public).\(locale, privacy: .public) unloaded")
            #endif
        } else {
            slots[locale] = slot
            #if DEBUG
            logger.debug("\(self.resourceBaseName, privacy: .public).\(locale, privacy: .public) released (refcount=\(slot.count, privacy: .public))")
            #endif
        }
    }

    private func load(locale: String) -> Value {
        let resource = resourceName(for: locale)
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt") else {
            logger.fault("\(resource, privacy: .public).txt not found in main bundle (run `make prepare`?)")
            return parse("")
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.fault("\(resource, privacy: .public).txt exists but could not be read")
            return parse("")
        }
        return parse(content)
    }

    /// RAII handle: releasing it (nil-assign or dealloc) decrements the
    /// refcount. The release closure captures only the registry and locale,
    /// never the Handle; the registry's slots hold `Value`, not the Handle, so
    /// there is no retain cycle.
    final class Handle {
        let value: Value
        private let onRelease: () -> Void

        fileprivate init(value: Value, onRelease: @escaping () -> Void) {
            self.value = value
            self.onRelease = onRelease
        }

        deinit {
            onRelease()
        }
    }
}
