import Foundation
import OSLog

enum JavaScriptStorageError: LocalizedError {
    case emptyKey
    case invalidKey
    case keyTooLong(encodedByteCount: Int, limit: Int)
    case valueTooLarge(byteCount: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "Storage key cannot be empty"
        case .invalidKey:
            return "Storage key contains invalid Unicode (e.g. unpaired surrogate)"
        case .keyTooLong(let count, let limit):
            return "Storage key too long after encoding (\(count) bytes, limit \(limit))"
        case .valueTooLarge(let count, let limit):
            return "Storage value too large (\(count) bytes, limit \(limit))"
        }
    }
}

/// File-per-key persistence. Filenames are `localStorage_<encoded>`
/// — the prefix reserves space for future storage kinds sharing the
/// same `rootURL`. Programmer errors throw; filesystem errors are
/// logged and swallowed (reads return nil, mutations drop).
struct JavaScriptStorage {
    let rootURL: URL

    /// APFS filename limit is 255 UTF-8 bytes; 200 leaves room for
    /// the prefix and any future suffix.
    static let maxEncodedKeyByteCount = 200
    /// Safety cap for runaway writes.
    static let maxValueByteCount = 10 * 1024 * 1024

    static let filenamePrefix = "localStorage_"

    /// No uppercase: keys are case-sensitive but the default APFS volume
    /// is not, so uppercase must percent-encode to keep case-distinct
    /// keys on distinct files.
    private static let safeKeyCharacters: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        return s
    }()

    /// Returns nil for keys with invalid Unicode (e.g. unpaired
    /// surrogates from JS) — caller surfaces as `.invalidKey`.
    static func encodeKey(_ key: String) -> String? {
        return key.addingPercentEncoding(withAllowedCharacters: safeKeyCharacters)
    }

    static func decodeFilename(_ filename: String) -> String? {
        guard filename.hasPrefix(filenamePrefix) else { return nil }
        return String(filename.dropFirst(filenamePrefix.count)).removingPercentEncoding
    }

    private func fileURL(for key: String) throws -> URL {
        if key.isEmpty { throw JavaScriptStorageError.emptyKey }
        guard let encoded = Self.encodeKey(key) else {
            throw JavaScriptStorageError.invalidKey
        }
        let byteCount = encoded.utf8.count
        if byteCount > Self.maxEncodedKeyByteCount {
            throw JavaScriptStorageError.keyTooLong(
                encodedByteCount: byteCount, limit: Self.maxEncodedKeyByteCount)
        }
        return rootURL.appendingPathComponent(Self.filenamePrefix + encoded)
    }

    func getItem(_ key: String) throws -> String? {
        let url = try fileURL(for: key)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            Logger.javaScriptEngine.error(
                "storage read failed for '\(key, privacy: .public)': \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Returns the written URL on success, nil if the disk wasn't
    /// actually touched (mkdir or write failed and got logged).
    /// Callers track self-writes via the returned URL.
    @discardableResult
    func setItem(_ key: String, _ value: String) throws -> URL? {
        let url = try fileURL(for: key)
        let byteCount = value.utf8.count
        if byteCount > Self.maxValueByteCount {
            throw JavaScriptStorageError.valueTooLarge(
                byteCount: byteCount, limit: Self.maxValueByteCount)
        }
        // Lazy mkdir so read-only sessions don't materialize the dir.
        do {
            try FileManager.default.createDirectory(
                at: rootURL, withIntermediateDirectories: true)
        } catch {
            Logger.javaScriptEngine.error(
                "storage mkdir failed at \(self.rootURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return nil
        }
        do {
            try Data(value.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            Logger.javaScriptEngine.error(
                "storage write failed for '\(key, privacy: .public)': \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Returns the removed URL on success, nil if the key didn't
    /// exist or the remove failed.
    @discardableResult
    func removeItem(_ key: String) throws -> URL? {
        let url = try fileURL(for: key)
        do {
            try FileManager.default.removeItem(at: url)
            return url
        } catch CocoaError.fileNoSuchFile {
            return nil
        } catch {
            Logger.javaScriptEngine.error(
                "storage remove failed for '\(key, privacy: .public)': \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Removes only files with `filenamePrefix` — keeps future
    /// storage kinds in the same `rootURL` intact. Returns the URLs
    /// actually removed so callers can track them as self-writes.
    @discardableResult
    func clear() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: rootURL.path) else { return [] }
        var removed: [URL] = []
        for name in names where name.hasPrefix(Self.filenamePrefix) {
            let url = rootURL.appendingPathComponent(name)
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(url)
            }
        }
        return removed
    }

    /// Sorted for deterministic `key(i)` indexing across calls.
    func keys() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: rootURL.path) else { return [] }
        return names
            .compactMap { Self.decodeFilename($0) }
            .sorted()
    }
}
