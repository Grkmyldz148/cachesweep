import Foundation

/// Concurrent, allocation-aware directory sizer.
/// Uses `totalFileAllocatedSize` (actual blocks on disk) so sparse files
/// (e.g. Docker.raw) are reported by real usage, not apparent size.
enum Scanner {

    /// Total on-disk size of a set of paths, scanned in parallel.
    static func size(of paths: [String]) async -> UInt64 {
        await withTaskGroup(of: UInt64.self) { group in
            for path in paths {
                group.addTask { directorySize(atPath: path) }
            }
            var total: UInt64 = 0
            for await partial in group { total += partial }
            return total
        }
    }

    /// Synchronous, fast recursive sizing of a single path.
    nonisolated static func directorySize(atPath rawPath: String) -> UInt64 {
        let fm = FileManager()
        let path = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }

        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey
        ]

        func allocated(_ u: URL) -> UInt64 {
            guard let v = try? u.resourceValues(forKeys: keys) else { return 0 }
            return UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }

        if !isDir.boolValue { return allocated(url) }

        guard let en = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],                       // include hidden — caches have dotfiles
            errorHandler: { _, _ in true }     // skip unreadable entries, keep going
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in en {
            if let v = try? fileURL.resourceValues(forKeys: keys), v.isRegularFile == true {
                total += UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
