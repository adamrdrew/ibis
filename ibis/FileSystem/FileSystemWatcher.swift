import Foundation
import CoreServices

/// Watches a directory subtree with FSEvents and reports the directories whose
/// contents changed, so the file tree can refresh live. Delivers directory-level
/// paths (a created/deleted/renamed file surfaces as a change to its parent
/// directory), which is exactly what we need to reload a node's children.
final class FileSystemWatcher {
    /// One reported change: the directory whose contents changed, plus whether
    /// FSEvents flagged it `MustScanSubDirs` — meaning events were coalesced or
    /// dropped (kernel queue overflow during heavy churn) and *everything below*
    /// the path may have changed, not just its immediate children.
    struct Event {
        let path: String
        let mustScanSubDirs: Bool
    }

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
    private let handler: ([Event]) -> Void

    init?(path: String, handler: @escaping ([Event]) -> Void) {
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
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info else { return }
            let box = Unmanaged<WeakBox>.fromOpaque(info).takeUnretainedValue()
            guard let watcher = box.watcher else { return }
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let paths = (cfPaths as NSArray).compactMap { $0 as? String }
            var events: [Event] = []
            events.reserveCapacity(paths.count)
            for (index, path) in paths.enumerated() where index < numEvents {
                let eventFlag = eventFlags[index]
                events.append(Event(
                    path: path,
                    mustScanSubDirs: eventFlag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                ))
            }
            watcher.handler(events)
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
