import Foundation
import Testing

/// `canonicalPath`/`isContained` gate whether entry, import, and fetch
/// paths stay inside the engine folder — the security boundary.
struct JavaScriptEnginePathTests {
    @Test func containmentRequiresAPathComponentBoundary() {
        let root = "/tmp/engine"
        #expect(JavaScriptEngine.isContained(
            url: URL(fileURLWithPath: "/tmp/engine/index.js"), in: root))
        #expect(JavaScriptEngine.isContained(
            url: URL(fileURLWithPath: "/tmp/engine"), in: root))  // the root itself
        // Sibling sharing the prefix string must not pass.
        #expect(!JavaScriptEngine.isContained(
            url: URL(fileURLWithPath: "/tmp/engine-evil/index.js"), in: root))
        #expect(!JavaScriptEngine.isContained(
            url: URL(fileURLWithPath: "/tmp/other/index.js"), in: root))
    }

    @Test func trailingSlashOnTheRootDoesNotDoubleUp() {
        #expect(JavaScriptEngine.isContained(
            url: URL(fileURLWithPath: "/tmp/engine/a.js"), in: "/tmp/engine/"))
        #expect(!JavaScriptEngine.isContained(
            url: URL(fileURLWithPath: "/tmp/engine-evil/a.js"), in: "/tmp/engine/"))
    }

    @Test func parentReferencesAreResolvedBeforeTheCheck() {
        let escape = URL(fileURLWithPath: "/tmp/engine/sub/../../outside/x.js")
        #expect(JavaScriptEngine.canonicalPath(for: escape) == "/tmp/outside/x.js")
        #expect(!JavaScriptEngine.isContained(url: escape, in: "/tmp/engine"))
    }

    private func makeDirectory(_ path: String, in base: URL) throws -> URL {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func newTemporaryBase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("path-test-\(UUID().uuidString)")
    }

    /// FSEvents reports the realpath form (`/private/var/...`).
    private func reportedForm(of url: URL) throws -> URL {
        URL(fileURLWithPath: try #require(
            url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath))
    }

    @Test func symlinkedPathsCanonicalizeToTheirTarget() throws {
        let base = newTemporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = try makeDirectory("real", in: base)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let viaLink = link.appendingPathComponent("file.js")
        let direct = real.appendingPathComponent("file.js")
        let nested = link.appendingPathComponent("sub/file.js")
        // Deletion events and a `_storage/` not created yet canonicalize while
        // missing, so the missing form has to match the existing one.
        let viaLinkBefore = JavaScriptEngine.canonicalPath(for: viaLink)
        let nestedBefore = JavaScriptEngine.canonicalPath(for: nested)
        try Data().write(to: direct)
        try Data().write(to: try makeDirectory("sub", in: real).appendingPathComponent("file.js"))
        #expect(viaLinkBefore == JavaScriptEngine.canonicalPath(for: viaLink))
        #expect(viaLinkBefore == JavaScriptEngine.canonicalPath(for: try reportedForm(of: direct)))
        #expect(nestedBefore == JavaScriptEngine.canonicalPath(for: nested))
        #expect(JavaScriptEngine.isContained(
            url: viaLink, in: JavaScriptEngine.canonicalPath(for: real)))
    }

    @Test func onlyRegularFilesInsideTheFolderAreFetchable() throws {
        let base = newTemporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = try makeDirectory("engine", in: base)
        let outside = try makeDirectory("outside", in: base)
        try Data().write(to: engine.appendingPathComponent("real.json"))
        try Data().write(to: outside.appendingPathComponent("secret.json"))
        _ = try makeDirectory("folder.json", in: engine)
        let links = [
            "link.json": "real.json", "escape.json": "../outside/secret.json",
            "dangling.json": "nowhere.json", "loop.json": "loop.json",
        ]
        for (name, destination) in links {
            try FileManager.default.createSymbolicLink(
                atPath: engine.appendingPathComponent(name).path, withDestinationPath: destination)
        }

        let root = JavaScriptEngine.canonicalPath(for: engine)
        let candidates = ["real.json", "link.json", "escape.json", "dangling.json", "loop.json",
                          "folder.json", "absent.json", "real.json/x.json"]
        #expect(candidates.filter {
            JavaScriptEngine.isFetchable(engine.appendingPathComponent($0), inFolder: root)
        } == ["real.json", "link.json"])
    }

    @Test func parentReferencesInMissingPathsFollowSymlinks() throws {
        let base = newTemporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = try makeDirectory("engine", in: base)
        try FileManager.default.createSymbolicLink(
            at: engine.appendingPathComponent("link"),
            withDestinationURL: try makeDirectory("outside/a/b", in: base))
        // The OS resolves `link/..` to outside/a, where the missing x.js would land.
        let escape = engine.appendingPathComponent("link/../x.js")
        #expect(!JavaScriptEngine.isContained(
            url: escape, in: JavaScriptEngine.canonicalPath(for: engine)))
    }
}
