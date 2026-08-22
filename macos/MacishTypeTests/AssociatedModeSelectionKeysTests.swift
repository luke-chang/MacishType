import Foundation
import Testing

private final class StubEngine: InputEngine {
    override var engineID: String { "StubSelectionKeys" }
    var declared: AssociatedModeIndexLabels = .numbers
    var conflicts: Set<Character> = []
    var baseConfiguration = CandidateWindowConfiguration()

    override var associatedModeIndexLabels: AssociatedModeIndexLabels { declared }
    override var associatedSelectionKeyConflicts: Set<Character> { conflicts }
    override var candidateWindowConfiguration: CandidateWindowConfiguration { baseConfiguration }
}

/// Serialized: the cases share the global UserDefaults policy key.
@MainActor
@Suite(.serialized)
struct AssociatedModeSelectionKeysTests {
    private func resolve(
        policy: InputEngine.AssociatedModeSelectionKeys? = nil,
        declared: InputEngine.AssociatedModeIndexLabels = .numbers,
        conflicts: Set<Character> = [],
        labels: String = "asdfghjkl",
        pageSize: Int = 9
    ) -> CandidateWindowConfiguration {
        let engine = StubEngine()
        engine.declared = declared
        engine.conflicts = conflicts
        var base = CandidateWindowConfiguration()
        base.indexLabels = labels
        base.pageSize = pageSize
        engine.baseConfiguration = base
        let key = InputEngine.associatedModeSelectionKeysKey
        if let policy {
            UserDefaults.standard.set(policy.rawValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        defer { UserDefaults.standard.removeObject(forKey: key) }
        return engine.resolveAssociatedCandidateWindowConfiguration()
    }

    /// The typing path uses the snapshot taken at activate: a change after
    /// activate resolves live but doesn't shift the ongoing session.
    @Test func activateSnapshotsTheResolutionForTheSession() {
        let engine = StubEngine()
        let key = InputEngine.associatedModeSelectionKeysKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(
            InputEngine.AssociatedModeSelectionKeys.shiftNumbers.rawValue, forKey: key)
        engine.activate(context: InputEngineContext(), clientIdentifier: nil)
        UserDefaults.standard.set(
            InputEngine.AssociatedModeSelectionKeys.numbers.rawValue, forKey: key)
        #expect(engine.associatedCandidateWindowConfiguration.indexLabelDigitsRequireShift)
        #expect(!engine.resolveAssociatedCandidateWindowConfiguration().indexLabelDigitsRequireShift)
    }

    // MARK: Follow engine

    @Test func theContractDefaultAppliesPlainDigits() {
        let config = resolve()
        #expect(config.indexLabels == "1234567890")
        #expect(config.pageSize == 9)  // min(base 9, 10)
        #expect(!config.indexLabelDigitsRequireShift)
    }

    @Test func digitBranchesCapPageSizeAtTen() {
        #expect(resolve(labels: "asdfghjkl;'", pageSize: 11).pageSize == 10)
    }

    @Test func inheritKeepsTheEngineConfiguration() {
        let config = resolve(declared: .inherit, conflicts: ["1", "!"])
        #expect(config.indexLabels == "asdfghjkl")
        #expect(config.pageSize == 9)
        #expect(!config.indexLabelDigitsRequireShift)
    }

    @Test func declarationWinsOverThePlatformDefault() {
        let config = resolve(declared: .shiftNumbers)
        #expect(config.indexLabels == "1234567890")
        #expect(config.indexLabelDigitsRequireShift)
    }

    /// Tone-style tables: digits are code keys but never lead a code, so
    /// their conflict set has no digits and plain digits stay usable.
    @Test func nonLeadingDigitsDoNotEscalate() {
        let config = resolve(conflicts: ["f", "a", "n"])
        #expect(config.indexLabels == "1234567890")
        #expect(!config.indexLabelDigitsRequireShift)
    }

    @Test func leadingDigitConflictsEscalateToShift() {
        let config = resolve(conflicts: ["1"])
        #expect(config.indexLabels == "1234567890")
        #expect(config.indexLabelDigitsRequireShift)
    }

    /// Both digit sets collide with leading roots: the label column drops
    /// entirely and pageSize keeps its engine value (no digit cap applies).
    @Test func doubleConflictDropsTheLabels() {
        let config = resolve(conflicts: ["1", "!"], labels: "asdfghjkl;'", pageSize: 11)
        #expect(config.indexLabels == "")
        #expect(config.pageSize == 11)
        #expect(config.handleNavigationKeys)
        #expect(!config.indexLabelDigitsRequireShift)
    }

    // MARK: Explicit user policy

    @Test func explicitChoiceSkipsEscalation() {
        let numbers = resolve(policy: .numbers, conflicts: ["1", "!"])
        #expect(numbers.indexLabels == "1234567890")
        #expect(!numbers.indexLabelDigitsRequireShift)

        let shifted = resolve(policy: .shiftNumbers, conflicts: ["1", "!"])
        #expect(shifted.indexLabels == "1234567890")
        #expect(shifted.indexLabelDigitsRequireShift)
    }

    @Test func explicitChoiceIgnoresTheDeclaration() {
        let config = resolve(policy: .numbers, declared: .inherit)
        #expect(config.indexLabels == "1234567890")
        #expect(!config.indexLabelDigitsRequireShift)
    }
}
