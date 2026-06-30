import Foundation
import CoreServices

/// Thin wrapper around FSEvents — the same kernel facility Spotlight uses.
/// Watches paths recursively and reports batches of changed file paths,
/// coalesced by the OS, with low latency and near-zero idle cost.
final class FileActivityMonitor {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.sweep.fsevents", qos: .utility)
    private let paths: [String]
    private let handler: (Set<String>) -> Void

    init(paths: [String], handler: @escaping (Set<String>) -> Void) {
        self.paths = paths
        self.handler = handler
    }

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagIgnoreSelf
        )

        // @convention(c) trampoline — no captures; self is recovered via `info`.
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<FileActivityMonitor>.fromOpaque(info).takeUnretainedValue()
            let cfArray = unsafeBitCast(eventPaths, to: NSArray.self)
            var changed = Set<String>()
            changed.reserveCapacity(count)
            for case let path as String in cfArray { changed.insert(path) }
            if !changed.isEmpty { monitor.handler(changed) }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.5,                       // batch latency (seconds)
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
