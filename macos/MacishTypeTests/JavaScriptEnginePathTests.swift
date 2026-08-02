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

    @Test func symlinkedPathsCanonicalizeToTheirTarget() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("path-test-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // Symlinks resolve only for paths that exist on disk; a missing
        // leaf keeps the link component (and so fails containment).
        let viaLink = link.appendingPathComponent("file.js")
        let direct = real.appendingPathComponent("file.js")
        #expect(JavaScriptEngine.canonicalPath(for: viaLink)
            != JavaScriptEngine.canonicalPath(for: direct))
        try Data().write(to: direct)
        #expect(JavaScriptEngine.canonicalPath(for: viaLink)
            == JavaScriptEngine.canonicalPath(for: direct))
        #expect(JavaScriptEngine.isContained(
            url: viaLink, in: JavaScriptEngine.canonicalPath(for: real)))
    }
}
