import AppKit
import Combine
import OSLog
import SwiftUI

/// Persists a user-selected file or folder URL across launches via
/// `URL.bookmarkData(options: .withSecurityScope)`, and manages the
/// security-scoped resource lifecycle.
///
/// Class is intentionally not `@MainActor`-isolated so engines (which run
/// on IMKit's main-thread dispatch but aren't formally main-actor) can
/// hold instances as stored properties. UI methods that mutate the
/// `@Published` state (`pick`, `clear`) are individually `@MainActor`.
final class SecurityScopedBookmark: ObservableObject {
    let identifier: String
    private var bookmarkKey: String { "\(identifier)_bookmarkData" }

    @Published private(set) var url: URL?
    private var activeScopedURL: URL?
    private var refCount: Int = 0

    init(identifier: String) {
        self.identifier = identifier
        url = resolveBookmark()
    }

    /// On accept, `validate` (if supplied) gates the bookmark write —
    /// returning a non-nil `(title, message)` rejects the pick and
    /// surfaces it as a sheet alert on `parent`.
    @MainActor
    func pick(
        parent: NSWindow? = nil,
        configure: (NSOpenPanel) -> Void,
        validate: ((URL) -> (title: String, message: String)?)? = nil
    ) async -> Bool {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        configure(panel)

        let response = await panel.beginSheetSafely(for: parent)
        guard response == .OK, let picked = panel.url else { return false }

        if let validate, let failure = validate(picked) {
            await Self.presentValidationAlert(failure: failure, parent: parent)
            return false
        }

        do {
            let data = try picked.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            Logger.securityScopedBookmark.error(
                "bookmark write failed for \(self.identifier, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return false
        }

        // Skip republish if user re-picked the same folder — @Published fires
        // on every assign, which would spuriously trigger downstream observers.
        if url != picked {
            forceResetScope()  // drop old folder's scope before url change
            url = picked
        }
        return true
    }

    @MainActor
    private static func presentValidationAlert(
        failure: (title: String, message: String),
        parent: NSWindow?
    ) async {
        let alert = NSAlert()
        alert.messageText = failure.title
        alert.informativeText = failure.message
        alert.alertStyle = .warning
        if let parent {
            await alert.beginSheetModal(for: parent)
        } else {
            alert.runModal()
        }
    }

    @MainActor
    func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        forceResetScope()
        url = nil
    }

    /// Acquires the security scope for `url` and increments an internal
    /// ref count. Only the first acquire starts the system scope; subsequent
    /// calls on the same target are bookkeeping-only. Caller must pair with
    /// `release()`. URL change (via pick / clear) forcibly resets count;
    /// pending releases from old-URL owners become silent no-ops.
    ///
    /// Returns nil when no bookmark stored OR when
    /// `startAccessingSecurityScopedResource()` returns false (dead bookmark).
    ///
    /// Caller is responsible for serializing access. In practice all
    /// callers run on main: IMKit dispatches engine.load()/unload() on
    /// main thread, FSEvents callback is set to the main DispatchQueue.
    func acquire() -> URL? {
        guard let target = url else { return nil }
        if activeScopedURL == nil {
            guard target.startAccessingSecurityScopedResource() else {
                return nil
            }
            activeScopedURL = target
        }
        refCount += 1
        return activeScopedURL
    }

    func release() {
        // Silent no-op when count is already 0 — expected after
        // `forceResetScope()` invalidated outstanding owners (e.g. user
        // picked a different folder while old engine still held a count).
        guard refCount > 0 else { return }
        refCount -= 1
        if refCount == 0 {
            activeScopedURL?.stopAccessingSecurityScopedResource()
            activeScopedURL = nil
        }
    }

    private func forceResetScope() {
        activeScopedURL?.stopAccessingSecurityScopedResource()
        activeScopedURL = nil
        refCount = 0
    }

    private func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            bookmarkDataIsStale: &isStale
        ) else {
            // Corrupt / unresolvable — drop it so we stop retrying every launch;
            // the engine falls back to not-configured until the user re-picks.
            dropBookmark(reason: "unresolvable")
            return nil
        }
        guard isStale else { return resolved }
        return refreshStaleBookmark(resolved)
    }

    /// Re-create a stale bookmark. Creating a security-scoped bookmark needs
    /// the URL under an active scope, so access it across `bookmarkData`. If
    /// the target is gone/inaccessible, drop the stored bookmark and return
    /// nil so the engine falls back to not-configured rather than log-erroring
    /// every launch. Trade-off: a bookmark to a temporarily-unmounted volume
    /// is also dropped, requiring a re-pick.
    private func refreshStaleBookmark(_ resolved: URL) -> URL? {
        let accessed = resolved.startAccessingSecurityScopedResource()
        defer { if accessed { resolved.stopAccessingSecurityScopedResource() } }
        guard accessed, FileManager.default.fileExists(atPath: resolved.path) else {
            dropBookmark(reason: "target unavailable")
            return nil
        }
        if let fresh = try? resolved.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return resolved
    }

    private func dropBookmark(reason: String) {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        Logger.securityScopedBookmark.notice(
            "cleared bookmark for \(self.identifier, privacy: .public): \(reason, privacy: .public)"
        )
    }
}

extension NSOpenPanel {
    @MainActor
    fileprivate func beginSheetSafely(for parent: NSWindow?) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            if let parent {
                self.beginSheetModal(for: parent) { response in
                    continuation.resume(returning: response)
                }
            } else {
                self.begin { response in
                    continuation.resume(returning: response)
                }
            }
        }
    }
}

// MARK: - Settings UI

struct BookmarkPickerSection<StatusRow: View>: View {
    let title: LocalizedStringKey
    let placeholder: LocalizedStringKey
    let buttonTitle: LocalizedStringKey
    @ObservedObject var bookmark: SecurityScopedBookmark
    let validatePick: ((URL) -> (title: String, message: String)?)?
    let configurePanel: (NSOpenPanel) -> Void
    /// Extra rows in the same section, below the picker (e.g. a status row).
    @ViewBuilder let statusRow: () -> StatusRow

    var body: some View {
        Section(title) {
            VStack(alignment: .leading, spacing: 8) {
                // Two branches: Text(verbatim:) for runtime-resolved paths,
                // Text(_:LocalizedStringKey) for the placeholder so .xcstrings
                // lookup runs. String(localized:) doesn't accept LocalizedStringKey.
                if let path = bookmark.url?.path {
                    Text(verbatim: path)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(path)
                        .textSelection(.enabled)
                } else {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    if bookmark.url != nil {
                        Button("Clear") { bookmark.clear() }
                    }
                    Button(buttonTitle) {
                        let parent = NSApp.keyWindow
                        Task {
                            _ = await bookmark.pick(
                                parent: parent,
                                configure: configurePanel,
                                validate: validatePick
                            )
                        }
                    }
                }
            }
            statusRow()
        }
    }
}

extension BookmarkPickerSection where StatusRow == EmptyView {
    init(
        title: LocalizedStringKey,
        placeholder: LocalizedStringKey,
        buttonTitle: LocalizedStringKey,
        bookmark: SecurityScopedBookmark,
        validatePick: ((URL) -> (title: String, message: String)?)?,
        configurePanel: @escaping (NSOpenPanel) -> Void
    ) {
        self.init(
            title: title, placeholder: placeholder, buttonTitle: buttonTitle,
            bookmark: bookmark, validatePick: validatePick,
            configurePanel: configurePanel
        ) { EmptyView() }
    }
}
