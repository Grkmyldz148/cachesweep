import Foundation

/// Find project markers by walking, for the disks Spotlight cannot answer for.
///
/// `mdfind` is the fast path and usually the only one needed. But a Spotlight
/// index can be missing, disabled, or simply stale, and the disks where that
/// happens are exactly the external ones a developer keeps their projects on.
/// On the machine this was written for, an external SSD reported "indexing
/// enabled" and returned zero hits for `package.json`, while a plain walk
/// found 81 of them.
///
/// That gap matters more than it sounds. Without this fallback, telling the
/// user "your projects are on that disk, add it as a scan root" would change
/// nothing at all: the sweep would run over the new root, ask Spotlight, get
/// silence, and report nothing found — the same failure, one step later.
enum ManifestWalk {

    /// Directories that can only cost time: build output and dependency trees
    /// (whose markers we don't want anyway — a manifest *inside* node_modules
    /// is not a project), plus the OS's own furniture.
    static let pruned: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "Pods", "vendor", "target",
        ".build", "build", "DerivedData", "Library", "System", ".Trash",
        "__pycache__", ".venv", "venv", ".next", ".nuxt", ".gradle",
    ]

    /// Paths of files named in `names`, found under `root`.
    /// Bounded in both depth and total entries visited: this runs on a whole
    /// volume, and an unbounded walk of one is not something a menu-bar app
    /// gets to do while the user waits.
    static func find(_ names: Set<String>, under root: String,
                     maxDepth: Int = 5, maxVisits: Int = 120_000,
                     fm: FileManager = FileManager()) -> [String: [String]] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root),
                                     includingPropertiesForKeys: Array(keys),
                                     options: [.skipsPackageDescendants],
                                     errorHandler: { _, _ in true }) else { return [:] }
        var out: [String: [String]] = [:]
        var visits = 0
        for case let url as URL in en {
            visits += 1
            if visits > maxVisits { break }
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: keys))?.isDirectory == true
            if isDir {
                if pruned.contains(name) || en.level >= maxDepth { en.skipDescendants() }
                continue
            }
            if names.contains(name) { out[name, default: []].append(url.path) }
        }
        return out
    }

    /// How many of `names` exist under `root` — the cheap version, for
    /// deciding whether a disk is worth offering at all.
    static func count(_ names: Set<String>, under root: String,
                      maxDepth: Int = 4, maxVisits: Int = 20_000) -> Int {
        find(names, under: root, maxDepth: maxDepth, maxVisits: maxVisits)
            .values.reduce(0) { $0 + $1.count }
    }
}
