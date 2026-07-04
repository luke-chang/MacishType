import CoreServices
import Foundation

/// RAII wrapper around a main-queue FSEventStream: the stream starts on
/// init and is stopped, invalidated, and released on deinit, so owners
/// tear down by dropping their reference (`watcher = nil` on main is a
/// deterministic, synchronous stop).
///
/// The stream retains a private box holding only the handler — never
/// the owner — so handlers must capture `weak self` (plus value types).
/// The box's final release may happen off the main thread.
final class FSEventsWatcher {
    /// nonisolated: retained by the FSEvents machinery, which may
    /// perform the final release on an arbitrary thread.
    private nonisolated final class HandlerBox {
        let handler: @MainActor ([String]) -> Void
        init(handler: @escaping @MainActor ([String]) -> Void) {
            self.handler = handler
        }
    }

    private let stream: FSEventStreamRef

    /// Returns nil when `FSEventStreamCreate` fails; logging is left to
    /// the caller, which knows the category and message that fit.
    init?(paths: [String], latency: CFTimeInterval,
          handler: @escaping @MainActor ([String]) -> Void) {
        let box = HandlerBox(handler: handler)
        // The stream copies this context and retains `info` for its own
        // lifetime, so the box stays valid for every callback regardless
        // of when or on which thread the watcher itself is torn down.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<HandlerBox>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                guard let info else { return }
                Unmanaged<HandlerBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        // UseCFTypes: eventPaths arrives as CFArray<CFString> instead of a
        // C-string vector — far easier to bridge into Swift.
        // Stream is queued to .main below, so the callback runs on main —
        // `assumeIsolated` is safe.
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let box = Unmanaged<HandlerBox>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { box.handler(paths) }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
            )
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
