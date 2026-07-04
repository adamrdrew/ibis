import Foundation
import CoreServices

/// Watches a directory subtree with FSEvents and reports the directories whose
/// contents changed, so the file tree can refresh live. Delivers directory-level
/// paths (a created/deleted/renamed file surfaces as a change to its parent
/// directory), which is exactly what we need to reload a node's children.
final class FileSystemWatcher {
    /// A heap box holding a *weak* back-reference to the watcher. FSEvents retains
    /// this box (not the watcher) for the stream's lifetime and releases it via
    /// the context's release callback when the stream is torn down. Because the
    /// callback reaches the watcher through a weak, atomically-loaded reference, a
    /// callback already in flight on the dispatch queue while the watcher
    /// deallocates simply sees `nil` and no-ops — no use-after-free.
    private final class WeakBox {
        weak var watcher: FileSystemWatcher?
    }

    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init?(path: String, handler: @escaping ([String]) -> Void) {
        self.handler = handler

        let box = WeakBox()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<WeakBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<WeakBox>.fromOpaque(info).takeUnretainedValue()
            guard let watcher = box.watcher else { return }
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let paths = (cfPaths as NSArray).compactMap { $0 as? String }
            watcher.handler(paths)
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else {
            // Stream creation failed, so nothing will ever call the context's
            // release callback — balance the passRetained here to avoid leaking
            // the box.
            Unmanaged<WeakBox>.fromOpaque(context.info!).release()
            return nil
        }

        box.watcher = self
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
