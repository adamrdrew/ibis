import Foundation
import CoreServices

/// Watches a directory subtree with FSEvents and reports the directories whose
/// contents changed, so the file tree can refresh live. Delivers directory-level
/// paths (a created/deleted/renamed file surfaces as a change to its parent
/// directory), which is exactly what we need to reload a node's children.
final class FileSystemWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init?(path: String, handler: @escaping ([String]) -> Void) {
        self.handler = handler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
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
            return nil
        }

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
