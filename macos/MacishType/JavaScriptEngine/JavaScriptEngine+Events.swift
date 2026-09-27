import AppKit
import JavaScriptCore
import OSLog

// MARK: - Event payloads and action mutators

extension JavaScriptEngine {

    /// Reference-type wrapper so `@convention(block)` closures can mutate a
    /// shared `[EngineAction]` buffer. Obj-C blocks capture by value by
    /// default; capturing a `var [EngineAction]` directly would write to
    /// snapshot copies invisible from outside the block.
    final class ActionSink {
        var actions: [EngineAction] = []
    }

    func makeEvent(
        keyEvent: KeyEventInput,
        context: InputEngineContext,
        candidateWindow: CandidateWindowState,
        sink: ActionSink
    ) -> JSValue {
        let pure = keyEvent.pureModifiers

        let event = JSValue(newObjectIn: jsContext)!
        let key = KeyboardEventMapping.webKey(for: keyEvent.keyCode, characters: keyEvent.characters)
        event.setObject(key, forKeyedSubscript: "key" as NSString)
        event.setObject(KeyboardEventMapping.webCode(for: keyEvent.keyCode),
                        forKeyedSubscript: "code" as NSString)
        event.setObject(keyEvent.charactersIgnoringModifiers ?? key,
                        forKeyedSubscript: "keyIgnoringModifiers" as NSString)
        event.setObject(pure.contains(.shift), forKeyedSubscript: "shiftKey" as NSString)
        event.setObject(pure.contains(.control), forKeyedSubscript: "ctrlKey" as NSString)
        event.setObject(pure.contains(.option), forKeyedSubscript: "altKey" as NSString)
        event.setObject(pure.contains(.command), forKeyedSubscript: "metaKey" as NSString)
        event.setObject(keyEvent.isRepeat, forKeyedSubscript: "repeat" as NSString)
        event.setObject(KeyboardEventMapping.location(for: keyEvent.keyCode),
                        forKeyedSubscript: "location" as NSString)

        // Web standard `getModifierState(key)`. Returns true only for the five
        // states macOS can faithfully report; everything else (NumLock /
        // ScrollLock / AltGraph / Hyper / Super / Symbol / etc.) returns false.
        // NumLock is host-dependent in the contract; Mac keyboards have Clear
        // in that position, so it stays false here.
        // "Fn" is intentionally not supported — NSEvent.ModifierFlags.function
        // gets set automatically on arrow / F-keys / Page Up/Down / Home / End
        // even when no Fn key is held, which would mislead callers.
        let modifiers = keyEvent.modifiers
        let getModifierState: @convention(block) (String) -> Bool = { stateKey in
            switch stateKey {
            case "Shift": return modifiers.contains(.shift)
            case "Control": return modifiers.contains(.control)
            case "Alt": return modifiers.contains(.option)
            case "Meta": return modifiers.contains(.command)
            case "CapsLock": return modifiers.contains(.capsLock)
            default: return false
            }
        }
        event.setObject(getModifierState, forKeyedSubscript: "getModifierState" as NSString)

        attachEventContext(to: event, context: context, candidateWindow: candidateWindow)
        attachMutators(to: event, sink: sink)
        return event
    }

    /// Mirrors the shape of TS `EventContext`: the fields every event payload
    /// (KeyEvent, ConfirmEvent) shares. Adding a new context field is now a
    /// one-line edit here instead of touching every makeXxxEvent helper.
    private func attachEventContext(
        to event: JSValue, context: InputEngineContext, candidateWindow: CandidateWindowState
    ) {
        event.setObject(context.markedText, forKeyedSubscript: "markedText" as NSString)
        event.setObject(context.stagedText, forKeyedSubscript: "stagedText" as NSString)
        event.setObject(context.isComposing, forKeyedSubscript: "isComposing" as NSString)
        event.setObject(context.isAssociating, forKeyedSubscript: "isAssociating" as NSString)
        // null, not undefined: the contract has engines test it directly.
        event.setObject(candidateWindow.message ?? NSNull(),
                        forKeyedSubscript: "message" as NSString)
        attachCandidateWindow(to: event, candidateWindow: candidateWindow)
    }

    private func attachCandidateWindow(
        to event: JSValue, candidateWindow: CandidateWindowState
    ) {
        let cw = JSValue(newObjectIn: jsContext)!
        cw.setObject(candidateWindow.isVisible,
                     forKeyedSubscript: "isVisible" as NSString)
        cw.setObject(candidateWindow.configuration.indexLabels,
                     forKeyedSubscript: "indexLabels" as NSString)
        cw.setObject(candidateWindow.configuration.pageSize,
                     forKeyedSubscript: "pageSize" as NSString)
        cw.setObject(candidateWindow.configuration.layoutDirection.rawValue,
                     forKeyedSubscript: "layoutDirection" as NSString)
        cw.setObject(candidateWindow.configuration.handleNavigationKeys,
                     forKeyedSubscript: "handleNavigationKeys" as NSString)
        cw.setObject(candidateWindow.configuration.handleIndexLabelKeys,
                     forKeyedSubscript: "handleIndexLabelKeys" as NSString)
        cw.setObject(candidateWindow.configuration.indexLabelDigitsRequireShift,
                     forKeyedSubscript: "indexLabelDigitsRequireShift" as NSString)
        cw.setObject(candidateWindow.pageRange.lowerBound,
                     forKeyedSubscript: "pageStart" as NSString)
        cw.setObject(candidateWindow.pageRange.upperBound,
                     forKeyedSubscript: "pageEnd" as NSString)
        let candidateIndex: @convention(block) (JSValue) -> Any = { value in
            let configuration = candidateWindow.configuration
            // The string form matches by first character only.
            if value.isString {
                guard let char = (value.toString() ?? "").first,
                      let index = configuration.candidateIndex(forTypedCharacter: char) else {
                    return NSNull()
                }
                return index
            }
            guard value.isObject else { return NSNull() }
            let code = Self.optString(value, "code") ?? ""
            let shift = Self.optBool(value, "shiftKey") ?? false
            let option = Self.optBool(value, "altKey") ?? false
            let keyText = Self.optString(value, "key")
            guard let index = configuration.candidateIndex(
                forWebCode: code, shift: shift, option: option,
                character: keyText.flatMap { $0.count == 1 ? $0.first : nil }) else {
                return NSNull()
            }
            return index
        }
        cw.setObject(candidateIndex, forKeyedSubscript: "candidateIndex" as NSString)
        let navigationIntent: @convention(block) (JSValue) -> Any = { jsEvent in
            guard jsEvent.isObject else { return NSNull() }
            let code = Self.optString(jsEvent, "code") ?? ""
            let shift = Self.optBool(jsEvent, "shiftKey") ?? false
            let option = Self.optBool(jsEvent, "altKey") ?? false
            guard let keyCode = KeyboardEventMapping.keyCode(forWebCode: code),
                  let intent = candidateWindow.configuration.navigationIntent(
                    keyCode: keyCode, shift: shift, option: option
                  ) else {
                return NSNull()
            }
            var result: [String: Any] = [
                "direction": Self.serializeNavigationDirection(intent.direction)
            ]
            if intent.wrapping {
                result["options"] = ["wrapping": true]
            }
            return result
        }
        cw.setObject(navigationIntent, forKeyedSubscript: "navigationIntent" as NSString)
        event.setObject(cw, forKeyedSubscript: "candidateWindow" as NSString)
    }

    func makeConfirmEvent(
        context: InputEngineContext,
        candidate: String,
        absoluteIndex: Int,
        raw: Candidate?,
        candidateWindow: CandidateWindowState,
        sink: ActionSink
    ) -> JSValue {
        let event = JSValue(newObjectIn: jsContext)!
        event.setObject(candidate, forKeyedSubscript: "candidate" as NSString)
        event.setObject(absoluteIndex, forKeyedSubscript: "absoluteIndex" as NSString)
        if let annotation = raw?.annotation {
            event.setObject(annotation, forKeyedSubscript: "annotation" as NSString)
        }
        if let payload = raw?.payload {
            event.setObject(payload, forKeyedSubscript: "payload" as NSString)
        }
        attachEventContext(to: event, context: context, candidateWindow: candidateWindow)
        attachMutators(to: event, sink: sink)
        return event
    }

    /// Reads an Int from `obj[key]` by the `intValue` rule.
    private static func optInt(_ obj: JSValue?, _ key: String) -> Int? {
        intValue(obj?.objectForKeyedSubscript(key))
    }

    /// A number with no fractional part that fits an Int, else nil: the rule
    /// for window fields, which reject what an integer option would truncate.
    static func wholeNumber(_ value: JSValue?) -> Int? {
        guard let value, value.isNumber else { return nil }
        return Int(exactly: value.toDouble())
    }

    /// nil for a missing, non-number or NaN value. Fractions truncate, and a
    /// number beyond an Int32, either infinity included, saturates rather
    /// than wrapping.
    static func intValue(_ value: JSValue?) -> Int? {
        guard let value, value.isNumber else { return nil }
        let number = value.toDouble()
        guard !number.isNaN else { return nil }
        return Int(min(max(number, Double(Int32.min)), Double(Int32.max)))
    }

    /// Reads a Bool from `obj[key]`. Returns nil for missing / non-boolean
    /// values (vs `toBool()` which silently coerces).
    private static func optBool(_ obj: JSValue?, _ key: String) -> Bool? {
        guard let v = resolved(obj?.objectForKeyedSubscript(key)), v.isBoolean else { return nil }
        return v.toBool()
    }

    /// Reads a String from `obj[key]`. Returns nil for missing / non-string
    /// values (vs `toString()` which silently stringifies).
    private static func optString(_ obj: JSValue?, _ key: String) -> String? {
        guard let v = resolved(obj?.objectForKeyedSubscript(key)), v.isString else { return nil }
        return v.toString()
    }

    /// Builds a `configure` closure for `EngineAction.updateCandidates` from
    /// flat JS options. Returns nil when no override fields are present so
    /// the engine default applies.
    static func parseCandidateWindowOverrides(
        _ opts: JSValue?
    ) -> ((inout CandidateWindowConfiguration) -> Void)? {
        guard let opts else { return nil }
        let layoutDirection = Self.optString(opts, "layoutDirection")
            .flatMap(CandidateWindow.LayoutDirection.init(rawValue:))
        // The configuration traps on labels or page sizes it can't hold.
        let indexLabels = Self.optString(opts, "indexLabels")
            .flatMap { CandidateWindowConfiguration.isValidIndexLabels($0) ? $0 : nil }
        let pageSize = Self.wholeNumber(opts.objectForKeyedSubscript("pageSize"))
            .flatMap { CandidateWindowConfiguration.isValidPageSize($0) ? $0 : nil }
        let handleNavigationKeys = Self.optBool(opts, "handleNavigationKeys")
        let handleIndexLabelKeys = Self.optBool(opts, "handleIndexLabelKeys")
        let indexLabelDigitsRequireShift = Self.optBool(opts, "indexLabelDigitsRequireShift")

        if layoutDirection == nil && indexLabels == nil && pageSize == nil
            && handleNavigationKeys == nil && handleIndexLabelKeys == nil
            && indexLabelDigitsRequireShift == nil {
            return nil
        }
        return { config in
            if let layoutDirection { config.layoutDirection = layoutDirection }
            if let indexLabels { config.indexLabels = indexLabels }
            if let pageSize { config.pageSize = pageSize }
            if let handleNavigationKeys { config.handleNavigationKeys = handleNavigationKeys }
            if let handleIndexLabelKeys { config.handleIndexLabelKeys = handleIndexLabelKeys }
            if let indexLabelDigitsRequireShift {
                config.indexLabelDigitsRequireShift = indexLabelDigitsRequireShift
            }
        }
    }

    /// Builds a `Candidate` from either a JS string or `{candidate, annotation?, payload?}` object.
    static func candidateFromJS(_ value: JSValue?) -> Candidate {
        guard let value = resolved(value) else { return Candidate("") }
        // Plain-string candidates skip the 3 property lookups — common path
        // when engines emit `[String]` or call `event.commit("text")`.
        guard value.isObject else { return Candidate(value.toString() ?? "") }
        let text = resolved(value.objectForKeyedSubscript("candidate"))?.toString() ?? ""
        let annotation = resolved(value.objectForKeyedSubscript("annotation"))?.toString()
        // The payload is opaque: a null goes back to the engine as null.
        let payload = value.objectForKeyedSubscript("payload")
        return Candidate(text, annotation: annotation,
                         payload: payload?.isUndefined == false ? payload : nil)
    }

    private func attachMutators(to event: JSValue, sink: ActionSink) {
        // cursor: nil vs 0 are distinct (nil = default-to-text-count, 0 =
        // caret at start). emphasis is a half-open character-index range
        // (NOT UTF-16). See EngineAction.updateMarkedText for staged semantics.
        let updateMarkedText: @convention(block) (JSValue?, JSValue?) -> Void = { textValue, options in
            let text = Self.resolved(textValue)?.toString() ?? ""
            let opts = Self.resolved(options)
            let cursor = Self.optInt(opts, "cursor")
            let staged = Self.optInt(opts, "staged") ?? 0
            var emphasis: Range<Int>?
            if let e = Self.resolved(opts?.objectForKeyedSubscript("emphasis")),
               let lo = Self.optInt(e, "start"), let hi = Self.optInt(e, "end"), lo <= hi {
                emphasis = lo..<hi
            }
            sink.actions.append(
                .updateMarkedText(text, cursor: cursor, emphasis: emphasis, staged: staged)
            )
        }
        let resetContext: @convention(block) () -> Void = {
            sink.actions.append(.resetContext)
        }
        // First param is JSValue (whole array) not [JSValue]: JSC's ObjC
        // bridge gives NSArray<NSString> for JS string arrays and Swift traps
        // casting NSTaggedPointerString to JSValue. Window fields in options
        // override the engine default for this one update.
        let updateCandidates: @convention(block) (JSValue, JSValue?) -> Void = { itemsArr, options in
            let opts = Self.resolved(options)
            let anchorAt = Self.optInt(opts, "anchorAt") ?? 0
            let initialHighlight = Self.optInt(opts, "initialHighlight") ?? 0
            let count = itemsArr.isArray ? Self.listCount(of: itemsArr) : 0
            // Keep every slot: `absoluteIndex` addresses this list.
            let candidates = (0..<count).map {
                Self.candidateFromJS(itemsArr.objectAtIndexedSubscript($0))
            }
            sink.actions.append(.updateCandidates(
                candidates,
                anchorAt: anchorAt,
                initialHighlight: initialHighlight,
                configure: Self.parseCandidateWindowOverrides(opts)))
        }
        // Only anchorAt applies — how the row looks is the host's call.
        let updateMessage: @convention(block) (JSValue?, JSValue?) -> Void = { textValue, options in
            let text = Self.resolved(textValue)?.toString() ?? ""
            let anchorAt = Self.optInt(Self.resolved(options), "anchorAt") ?? 0
            sink.actions.append(.updateMessage(text, anchorAt: anchorAt))
        }
        // Accepts either a plain string or `{candidate, annotation?, payload?}` —
        // engines reusing a Candidate received in candidateConfirmed can pass
        // it back to preserve metadata.
        let commit: @convention(block) (JSValue) -> Void = { value in
            sink.actions.append(.commit(Self.candidateFromJS(value)))
        }
        let commitSelectedCandidate: @convention(block) () -> Void = {
            sink.actions.append(.commitSelectedCandidate)
        }
        // A non-number is a no-op; the window drops an index off the page.
        let commitCandidateAtIndex: @convention(block) (JSValue?) -> Void = { indexValue in
            guard let index = Self.intValue(indexValue) else { return }
            sink.actions.append(.commitCandidateAtIndex(index))
        }
        let navigateCandidates: @convention(block) (String, JSValue?) -> Void = { dirStr, options in
            guard let dir = Self.parseNavigationDirection(dirStr) else { return }
            let wrapping = Self.optBool(Self.resolved(options), "wrapping") ?? false
            sink.actions.append(.navigateCandidates(dir, wrapping: wrapping))
        }
        let flushStaged: @convention(block) (JSValue?) -> Void = { append in
            let text = Self.resolved(append)?.toString() ?? ""
            sink.actions.append(.flushStaged(text))
        }
        let enterAssociatedMode: @convention(block) (JSValue?, JSValue?) -> Void = { [weak self] heldValue, candidatesValue in
            let heldText = Self.resolved(heldValue)?.toString() ?? ""
            // One-arg form falls back to the system AssociatedDictionary.
            let candidates = Self.textArray(candidatesValue)
                ?? self?.lookupAssociatedCandidates(forHeldText: heldText) ?? []
            sink.actions.append(.enterAssociatedMode(heldText, candidates))
        }
        // One sound per event: repeat calls collapse, as in hostglue.js.
        var beeped = false
        let beep: @convention(block) () -> Void = {
            guard !beeped else { return }
            beeped = true
            sink.actions.append(.beep)
        }

        event.setObject(updateMarkedText, forKeyedSubscript: "updateMarkedText" as NSString)
        event.setObject(resetContext, forKeyedSubscript: "resetContext" as NSString)
        event.setObject(updateCandidates, forKeyedSubscript: "updateCandidates" as NSString)
        event.setObject(updateMessage, forKeyedSubscript: "updateMessage" as NSString)
        event.setObject(commit, forKeyedSubscript: "commit" as NSString)
        event.setObject(commitSelectedCandidate, forKeyedSubscript: "commitSelectedCandidate" as NSString)
        event.setObject(commitCandidateAtIndex, forKeyedSubscript: "commitCandidateAtIndex" as NSString)
        event.setObject(navigateCandidates, forKeyedSubscript: "navigateCandidates" as NSString)
        event.setObject(flushStaged, forKeyedSubscript: "flushStaged" as NSString)
        event.setObject(enterAssociatedMode, forKeyedSubscript: "enterAssociatedMode" as NSString)
        event.setObject(beep, forKeyedSubscript: "beep" as NSString)
    }

    private static func parseNavigationDirection(_ str: String) -> NavigationDirection? {
        switch str {
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        case "home": return .home
        case "end": return .end
        case "pageUp": return .pageUp
        case "pageDown": return .pageDown
        case "pageForward": return .pageForward
        case "pageBackward": return .pageBackward
        case "itemForward": return .itemForward
        case "itemBackward": return .itemBackward
        default:
            Logger.javaScriptEngine.notice(
                "unknown navigation direction: \(str, privacy: .public) — ignored")
            return nil
        }
    }

    private static func serializeNavigationDirection(_ dir: NavigationDirection) -> String {
        switch dir {
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pageUp"
        case .pageDown: return "pageDown"
        case .pageForward: return "pageForward"
        case .pageBackward: return "pageBackward"
        case .itemForward: return "itemForward"
        case .itemBackward: return "itemBackward"
        }
    }
}
