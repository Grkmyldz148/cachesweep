import Foundation
import Observation

/// A live-tracked location that is actively changing on disk.
@Observable
final class ActivityEntry: Identifiable {
    let id: String          // bucket path (stable identity)
    let label: String       // display (~-relative)
    let symbol: String
    let isKnown: Bool       // matches a curated rule?
    var size: UInt64 = 0
    var baseline: UInt64 = 0
    var hasBaseline = false
    var lastChange: Date
    var changeCount = 0

    init(id: String, label: String, symbol: String, isKnown: Bool, lastChange: Date) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.isKnown = isKnown
        self.lastChange = lastChange
    }

    /// Growth since we first measured it this session.
    var delta: Int64 { hasBaseline ? Int64(size) - Int64(baseline) : 0 }
}

struct Bucket {
    let path: String
    let label: String
    let symbol: String
    let isKnown: Bool
}

/// Maps a raw changed file path to a meaningful "bucket": either a known
/// rule root, or an auto-discovered cache-like ancestor. Anything that
/// doesn't look cache-related is ignored (returns nil).
enum Buckets {
    /// Path components that mark a cache-like boundary.
    static let markers: Set<String> = [
        "Caches", ".cache", "DerivedData", "node_modules",
        ".gradle", ".npm", ".ollama", "CocoaPods", ".cargo",
        ".pub-cache", ".m2", "vendor"
    ]

    static func classify(
        _ path: String,
        knownRoots: [(path: String, name: String, symbol: String)]
    ) -> Bucket? {
        // 1) Inside a curated rule?
        for r in knownRoots where path == r.path || path.hasPrefix(r.path + "/") {
            return Bucket(path: r.path, label: shortLabel(r.path), symbol: r.symbol, isKnown: true)
        }
        // 2) Under a cache-like ancestor → discover it.
        let comps = (path as NSString).pathComponents
        for (i, c) in comps.enumerated() where markers.contains(c) {
            let bucketPath = NSString.path(withComponents: Array(comps[0...i]))
            return Bucket(path: bucketPath, label: shortLabel(bucketPath),
                          symbol: symbol(for: c), isKnown: false)
        }
        return nil
    }

    static func shortLabel(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static func symbol(for marker: String) -> String {
        switch marker {
        case "node_modules": return "shippingbox"
        case "DerivedData":  return "hammer.fill"
        case ".gradle", ".m2": return "hammer"
        case ".ollama":      return "brain"
        default:             return "questionmark.folder"
        }
    }
}
