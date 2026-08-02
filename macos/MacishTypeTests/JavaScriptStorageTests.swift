import Foundation
import Testing

struct JavaScriptStorageTests {
    private func makeStorage() -> (storage: JavaScriptStorage, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-test-\(UUID().uuidString)")
        return (JavaScriptStorage(rootURL: root), root)
    }

    // MARK: Filename encoding

    @Test func encodedKeysRoundTripThroughFilenames() throws {
        for key in ["simple", "UPPER", "中文鍵", "a b/c?d#e", "under_dash-.0"] {
            let encoded = try #require(JavaScriptStorage.encodeKey(key))
            let filename = JavaScriptStorage.filenamePrefix + encoded
            #expect(JavaScriptStorage.decodeFilename(filename) == key)
        }
    }

    /// Keys are case-sensitive but the default APFS volume is not, so
    /// uppercase must leave the safe set and percent-encode.
    @Test func caseDistinctKeysMapToCaseDistinctFilenames() throws {
        let upper = try #require(JavaScriptStorage.encodeKey("Key"))
        let lower = try #require(JavaScriptStorage.encodeKey("key"))
        #expect(upper.lowercased() != lower.lowercased())
        #expect(upper.contains("%"))
    }

    @Test func foreignFilenamesDecodeToNothing() {
        #expect(JavaScriptStorage.decodeFilename("other.txt") == nil)
        #expect(JavaScriptStorage.decodeFilename(".localStorage_x") == nil)
        #expect(JavaScriptStorage.decodeFilename("localStorage_%41") == "A")
    }

    // MARK: CRUD

    @Test func setThenGetRoundTripsValues() throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(try storage.setItem("鍵 A/B", "值\n二行"))
        #expect(url.lastPathComponent.hasPrefix(JavaScriptStorage.filenamePrefix))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try storage.getItem("鍵 A/B") == "值\n二行")
    }

    @Test func missingKeyReadsAsNilWithoutCreatingTheRoot() throws {
        let (storage, root) = makeStorage()
        #expect(try storage.getItem("absent") == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func removeItemReportsWhetherAnythingWasRemoved() throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        try storage.setItem("k", "v")
        #expect(try storage.removeItem("k") != nil)
        #expect(try storage.getItem("k") == nil)
        #expect(try storage.removeItem("k") == nil)
    }

    @Test func clearOnlyTouchesPrefixedFiles() throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        try storage.setItem("a", "1")
        try storage.setItem("b", "2")
        let foreign = root.appendingPathComponent("other.txt")
        try Data("keep".utf8).write(to: foreign)

        #expect(storage.clear().count == 2)
        #expect(storage.keys().isEmpty)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test func keysAreSortedAndDecodedFromFilenames() throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        for key in ["b", "a", "C"] { try storage.setItem(key, "x") }
        #expect(storage.keys() == ["C", "a", "b"])
    }

    @Test func emptyDirectoryBehavesAsEmptyStorage() {
        let (storage, _) = makeStorage()
        #expect(storage.keys().isEmpty)
        #expect(storage.clear().isEmpty)
    }

    // MARK: Limits

    @Test func emptyKeyThrows() {
        let (storage, _) = makeStorage()
        let error = #expect(throws: JavaScriptStorageError.self) {
            try storage.getItem("")
        }
        guard case .emptyKey = error else {
            Issue.record("expected emptyKey, got \(String(describing: error))")
            return
        }
    }

    @Test func encodedKeyLengthIsCappedAtTheLimit() throws {
        let (storage, root) = makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let limit = JavaScriptStorage.maxEncodedKeyByteCount
        try storage.setItem(String(repeating: "k", count: limit), "ok")

        let error = #expect(throws: JavaScriptStorageError.self) {
            try storage.setItem(String(repeating: "k", count: limit + 1), "x")
        }
        guard case .keyTooLong = error else {
            Issue.record("expected keyTooLong, got \(String(describing: error))")
            return
        }
    }

    @Test func oversizedValuesAreRejected() {
        let (storage, _) = makeStorage()
        let oversized = String(repeating: "v", count: JavaScriptStorage.maxValueByteCount + 1)
        let error = #expect(throws: JavaScriptStorageError.self) {
            try storage.setItem("k", oversized)
        }
        guard case .valueTooLarge = error else {
            Issue.record("expected valueTooLarge, got \(String(describing: error))")
            return
        }
    }
}
