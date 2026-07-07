import Foundation

/// What actually happened while cleaning one target.
struct CleanOutcome: Sendable {
    var freed: UInt64 = 0
    var failedCount = 0
    var firstError: String?

    mutating func recordFailure(_ error: Error) {
        failedCount += 1
        if firstError == nil { firstError = error.localizedDescription }
    }

    mutating func merge(_ other: CleanOutcome) {
        freed += other.freed
        failedCount += other.failedCount
        if firstError == nil { firstError = other.firstError }
    }
}

/// Performs the actual deletion. Permanent (real reclaim), not Trash —
/// the whole point is to free space, and these are regenerable caches.
enum Cleaner {

    /// Cleans one target, returning the bytes actually freed plus any
    /// failures — unwritable (e.g. root-owned) entries are skipped, not
    /// counted as freed, and reported so the UI can tell the user.
    nonisolated static func clean(_ target: CleanTarget) -> CleanOutcome {
        let fm = FileManager()
        var outcome = CleanOutcome()

        for path in target.expandedPaths {
            guard fm.fileExists(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)

            switch target.strategy {
            case .directory:
                let size = Scanner.directorySize(atPath: path)
                do {
                    try fm.removeItem(at: url)
                    outcome.freed += size
                } catch {
                    outcome.recordFailure(error)
                }

            case .contents:
                let items: [URL]
                do {
                    items = try fm.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: nil, options: []
                    )
                } catch {
                    outcome.recordFailure(error)
                    continue
                }
                for item in items {
                    let size = Scanner.directorySize(atPath: item.path)
                    do {
                        try fm.removeItem(at: item)
                        outcome.freed += size
                    } catch {
                        outcome.recordFailure(error)
                    }
                }
            }
        }
        return outcome
    }
}
