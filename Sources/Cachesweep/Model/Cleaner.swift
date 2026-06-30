import Foundation

/// Performs the actual deletion. Permanent (real reclaim), not Trash —
/// the whole point is to free space, and these are regenerable caches.
enum Cleaner {

    /// Cleans one target, returning the number of bytes actually freed.
    /// Unwritable (e.g. root-owned) entries are skipped and not counted.
    nonisolated static func clean(_ target: CleanTarget) -> UInt64 {
        let fm = FileManager()
        var freed: UInt64 = 0

        for path in target.expandedPaths {
            guard fm.fileExists(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)

            switch target.strategy {
            case .directory:
                let size = Scanner.directorySize(atPath: path)
                if (try? fm.removeItem(at: url)) != nil { freed += size }

            case .contents:
                guard let items = try? fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: []
                ) else { continue }
                for item in items {
                    let size = Scanner.directorySize(atPath: item.path)
                    if (try? fm.removeItem(at: item)) != nil { freed += size }
                }
            }
        }
        return freed
    }
}
