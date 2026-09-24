/// Shared destructuring for engine results. `EngineAction` isn't `Equatable`
/// (it carries a closure), so tests match the case + associated value rather
/// than comparing with `==`.

let visibleCandidateWindow = CandidateWindowState(
    isVisible: true, configuration: CandidateWindowConfiguration(), message: nil,
    pageRange: 0..<CandidateWindowConfiguration().pageSize)

/// The appended string of a lone `.flushStaged(_)`, else nil.
func flushedText(_ actions: [EngineAction]) -> String? {
    guard actions.count == 1, case .flushStaged(let text) = actions[0] else { return nil }
    return text
}

/// The held text and follow-ups of a lone `.enterAssociatedMode`, else nil.
func associatedMode(_ actions: [EngineAction]) -> (held: String, candidates: [String])? {
    guard actions.count == 1,
          case .enterAssociatedMode(let held, let candidates) = actions[0] else { return nil }
    return (held, candidates)
}

func beeped(_ actions: [EngineAction]) -> Bool {
    actions.contains { if case .beep = $0 { true } else { false } }
}

func resetsContext(_ actions: [EngineAction]) -> Bool {
    actions.contains { if case .resetContext = $0 { true } else { false } }
}

/// The text and staged length of a lone `.updateMarkedText`, else nil.
func markedText(_ actions: [EngineAction]) -> (text: String, staged: Int)? {
    guard actions.count == 1,
          case .updateMarkedText(let text, _, _, let staged) = actions[0] else { return nil }
    return (text, staged)
}
