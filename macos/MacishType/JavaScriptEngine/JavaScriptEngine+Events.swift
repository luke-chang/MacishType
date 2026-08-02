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
        let candidateIndex: @convention(block) (String) -> Any = { char in
            guard let firstChar = char.first,
                  let index = candidateWindow.configuration.candidateIndex(for: firstChar) else {
                return NSNull()
            }
            return index
        }
        cw.setObject(candidateIndex, forKeyedSubscript: "candidateIndex" as NSString)
        let navigationIntent: @convention(block) (JSValue) -> Any = { jsEvent in
            let code = jsEvent.objectForKeyedSubscript("code")?.toString() ?? ""
            let shift = jsEvent.objectForKeyedSubscript("shiftKey")?.toBool() ?? false
            let option = jsEvent.objectForKeyedSubscript("altKey")?.toBool() ?? false
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

    /// Reads an Int from `obj[key]`. Returns nil for missing / non-number
    /// values (vs `toInt32()` which silently coerces to 0).
    private static func optInt(_ obj: JSValue?, _ key: String) -> Int? {
        guard let v = resolved(obj?.objectForKeyedSubscript(key)), v.isNumber else { return nil }
        return Int(v.toInt32())
    }

    /// Reads a Bool from `obj[key]`. Returns nil for missing / non-boolean
    /// values (vs `toBool()` which silently coerces).
    private static func optBool(_ obj: JSValue?, _ key: String) -> Bool? {
        guard let v = resolved(obj?.objectForKeyedSubscript(key)), v.isBoolean else { return nil }
        return v.toBool()
    }

    /// Builds a `configure` closure for `EngineAction.updateCandidates` from
    /// flat JS options. Returns nil when no override fields are present so
    /// the engine default applies.
    private static func parseCandidateWindowOverrides(
        _ opts: JSValue?
    ) -> ((inout CandidateWindowConfiguration) -> Void)? {
        guard let opts else { return nil }
        let layoutString = Self.resolved(opts.objectForKeyedSubscript("layoutDirection"))?.toString()
        let layoutDirection = layoutString.flatMap(CandidateWindow.LayoutDirection.init(rawValue:))
        let indexLabels = Self.resolved(opts.objectForKeyedSubscript("indexLabels"))?.toString()
        let pageSize = Self.optInt(opts, "pageSize")
        let handleNavigationKeys = Self.optBool(opts, "handleNavigationKeys")
        let handleIndexLabelKeys = Self.optBool(opts, "handleIndexLabelKeys")

        if layoutDirection == nil && indexLabels == nil && pageSize == nil
            && handleNavigationKeys == nil && handleIndexLabelKeys == nil {
            return nil
        }
        return { config in
            if let layoutDirection { config.layoutDirection = layoutDirection }
            if let indexLabels { config.indexLabels = indexLabels }
            if let pageSize { config.pageSize = pageSize }
            if let handleNavigationKeys { config.handleNavigationKeys = handleNavigationKeys }
            if let handleIndexLabelKeys { config.handleIndexLabelKeys = handleIndexLabelKeys }
        }
    }

    /// Builds a `Candidate` from either a JS string or `{candidate, annotation?, payload?}` object.
    /// Falls back to `value.toString()` when the object lacks `candidate`.
    private static func candidateFromJS(_ value: JSValue) -> Candidate {
        // Plain-string candidates skip the 3 property lookups — common path
        // when engines emit `[String]` or call `event.commit("text")`.
        if value.isString { return Candidate(value.toString() ?? "") }
        if let textVal = Self.resolved(value.objectForKeyedSubscript("candidate")) {
            let annotation = Self.resolved(value.objectForKeyedSubscript("annotation"))?.toString()
            let payload = Self.resolved(value.objectForKeyedSubscript("payload"))
            return Candidate(textVal.toString() ?? "", annotation: annotation, payload: payload)
        }
        return Candidate(value.toString() ?? "")
    }

    private func attachMutators(to event: JSValue, sink: ActionSink) {
        // cursor: nil vs 0 are distinct (nil = default-to-text-count, 0 =
        // caret at start). emphasis is a half-open character-index range
        // (NOT UTF-16). See EngineAction.updateMarkedText for staged semantics.
        let updateMarkedText: @convention(block) (String, JSValue?) -> Void = { text, options in
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
        // items accepts [String] (backward-compatible) or [{text, annotation?,
        // payload?}] objects — "text" key picks the object branch, otherwise
        // toString fallback. First param is JSValue (whole array) not [JSValue]:
        // JSC's ObjC bridge gives NSArray<NSString> for JS string arrays and
        // Swift traps casting NSTaggedPointerString to JSValue.
        // options may include layoutDirection / indexLabels / pageSize to
        // override engine default config for this single update (mirrors
        // Swift's `configure` closure on the action).
        let updateCandidates: @convention(block) (JSValue, JSValue?) -> Void = { itemsArr, options in
            let opts = Self.resolved(options)
            let anchorAt = Self.optInt(opts, "anchorAt") ?? 0
            let initialHighlight = Self.optInt(opts, "initialHighlight") ?? 0
            let count = Int(itemsArr.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            let candidates = (0..<count).compactMap { i -> Candidate? in
                guard let item = itemsArr.objectAtIndexedSubscript(i) else { return nil }
                return Self.candidateFromJS(item)
            }
            sink.actions.append(.updateCandidates(
                candidates,
                anchorAt: anchorAt,
                initialHighlight: initialHighlight,
                configure: Self.parseCandidateWindowOverrides(opts)))
        }
        // Accepts either a plain string or `{text, annotation?, payload?}` —
        // engines reusing a Candidate received in candidateConfirmed can pass
        // it back to preserve metadata.
        let commit: @convention(block) (JSValue) -> Void = { value in
            sink.actions.append(.commit(Self.candidateFromJS(value)))
        }
        let commitSelectedCandidate: @convention(block) () -> Void = {
            sink.actions.append(.commitSelectedCandidate)
        }
        let commitCandidateAtIndex: @convention(block) (Int) -> Void = { index in
            sink.actions.append(.commitCandidateAtIndex(index))
        }
        let navigateCandidates: @convention(block) (String, JSValue?) -> Void = { dirStr, options in
            let dir = Self.parseNavigationDirection(dirStr)
            let wrapping = Self.resolved(options)?
                .objectForKeyedSubscript("wrapping")?.toBool() ?? false
            sink.actions.append(.navigateCandidates(dir, wrapping: wrapping))
        }
        let flushStaged: @convention(block) (JSValue?) -> Void = { append in
            let text = Self.resolved(append)?.toString() ?? ""
            sink.actions.append(.flushStaged(text))
        }
        let enterAssociatedMode: @convention(block) (String, JSValue?) -> Void = { [weak self] heldChar, candidatesValue in
            // Two-arg form uses the JS-supplied array; one-arg falls back to
            // the system AssociatedDictionary lookup.
            let candidates: [String]
            if let resolved = Self.resolved(candidatesValue),
               resolved.isArray, let arr = resolved.toArray() as? [String] {
                candidates = arr
            } else {
                candidates = heldChar.first.flatMap { self?.lookupAssociatedCandidates(for: $0) } ?? []
            }
            sink.actions.append(.enterAssociatedMode(heldChar, candidates))
        }

        event.setObject(updateMarkedText, forKeyedSubscript: "updateMarkedText" as NSString)
        event.setObject(resetContext, forKeyedSubscript: "resetContext" as NSString)
        event.setObject(updateCandidates, forKeyedSubscript: "updateCandidates" as NSString)
        event.setObject(commit, forKeyedSubscript: "commit" as NSString)
        event.setObject(commitSelectedCandidate, forKeyedSubscript: "commitSelectedCandidate" as NSString)
        event.setObject(commitCandidateAtIndex, forKeyedSubscript: "commitCandidateAtIndex" as NSString)
        event.setObject(navigateCandidates, forKeyedSubscript: "navigateCandidates" as NSString)
        event.setObject(flushStaged, forKeyedSubscript: "flushStaged" as NSString)
        event.setObject(enterAssociatedMode, forKeyedSubscript: "enterAssociatedMode" as NSString)
    }

    private static func parseNavigationDirection(_ str: String) -> NavigationDirection {
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
            Logger.javaScriptEngine.error(
                "unknown navigation direction: \(str, privacy: .public), defaulting to .down")
            return .down
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
